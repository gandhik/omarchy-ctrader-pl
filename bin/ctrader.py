"""Minimal cTrader Open API client — standard library only.

The Open API speaks Protobuf on port 5035 and JSON on port 5036. We use the
JSON port so this needs no protobuf runtime and no pip install.

Wire format on 5036, established by probing the demo endpoint: messages are
bare JSON objects with NO length prefix (sending a 4-byte prefix earns a
"Corrupted frame." error back). Replies arrive the same way, so reads are
framed by incrementally JSON-decoding a growing buffer.
"""

import bisect
import json
import os
import socket
import ssl
import time
import urllib.parse
import urllib.request
import codecs

# --- payload types we use (ProtoOAPayloadType / ProtoPayloadType) -----------
HEARTBEAT_EVENT = 51
APPLICATION_AUTH_REQ = 2100
APPLICATION_AUTH_RES = 2101
ACCOUNT_AUTH_REQ = 2102
ACCOUNT_AUTH_RES = 2103
ASSET_LIST_REQ = 2112
ASSET_LIST_RES = 2113
SYMBOLS_LIST_REQ = 2114
SYMBOLS_LIST_RES = 2115
SYMBOL_BY_ID_REQ = 2116
SYMBOL_BY_ID_RES = 2117
TRADER_REQ = 2121
TRADER_RES = 2122
RECONCILE_REQ = 2124
RECONCILE_RES = 2125
ERROR_RES = 2142
GET_ACCOUNTS_BY_TOKEN_REQ = 2149
GET_ACCOUNTS_BY_TOKEN_RES = 2150
GET_POSITION_UNREALIZED_PNL_REQ = 2187
GET_POSITION_UNREALIZED_PNL_RES = 2188

ENDPOINTS = {
    "demo": ("demo.ctraderapi.com", 5036),
    "live": ("live.ctraderapi.com", 5036),
}

TOKEN_URL = "https://openapi.ctrader.com/apps/token"
AUTH_URL = "https://id.ctrader.com/my/settings/openapi/grantingaccess/"


class CTraderError(RuntimeError):
    """A ProtoOAErrorRes came back instead of the response we asked for."""

    def __init__(self, code, description):
        super().__init__(f"{code}: {description}")
        self.code = code
        self.description = description


def scale(value, money_digits):
    """Money on the wire is an integer scaled by 10^moneyDigits."""
    if value is None:
        return 0.0
    return float(value) / (10 ** int(money_digits if money_digits is not None else 2))


class CTraderClient:
    def __init__(self, environment="demo", timeout=25.0):
        if environment not in ENDPOINTS:
            raise ValueError(f"environment must be demo or live, got {environment!r}")
        self.host, self.port = ENDPOINTS[environment]
        self.environment = environment
        self.timeout = timeout
        self.sock = None
        self._buf = ""
        self._decoder = None
        self._msg_id = 0
        self._last_send = 0.0
        # Unsolicited events (spot ticks, execution events) collected while
        # waiting on a response, so callers can drain them if they care.
        self.events = []

    # ---------------------------------------------------------- connection
    def connect(self):
        ctx = ssl.create_default_context()
        raw = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock = ctx.wrap_socket(raw, server_hostname=self.host)
        self.sock.settimeout(self.timeout)
        self._buf = ""
        self._decoder = codecs.getincrementaldecoder("utf-8")()
        return self

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def __enter__(self):
        return self.connect()

    def __exit__(self, *exc):
        self.close()

    # ------------------------------------------------------------- framing
    def send(self, payload_type, payload=None, client_msg_id=None):
        self._msg_id += 1
        msg_id = client_msg_id or f"m{self._msg_id}"
        blob = json.dumps({
            "clientMsgId": msg_id,
            "payloadType": payload_type,
            "payload": payload or {},
        }).encode("utf-8")
        self.sock.sendall(blob)
        self._last_send = time.monotonic()
        return msg_id

    def _read_message(self, deadline):
        """Return the next complete JSON object from the socket."""
        dec = json.JSONDecoder()
        while True:
            stripped = self._buf.lstrip()
            if stripped:
                try:
                    obj, end = dec.raw_decode(stripped)
                    self._buf = stripped[end:]
                    return obj
                except ValueError:
                    pass  # incomplete — need more bytes
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for a cTrader message")
            self.sock.settimeout(remaining)
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("cTrader closed the connection")
            self._buf += self._decoder.decode(chunk)

    def heartbeat(self):
        """The proxy drops idle connections; send this at least every 20s."""
        self.send(HEARTBEAT_EVENT, {})

    def seconds_since_send(self):
        return time.monotonic() - self._last_send

    # ------------------------------------------------------------ requests
    def request(self, payload_type, payload=None, expect=None, timeout=None):
        """Send a request and return the payload of its matching response.

        Messages that are not the reply we asked for (heartbeats, spot events,
        execution events) are set aside rather than mistaken for the answer.
        """
        msg_id = self.send(payload_type, payload)
        deadline = time.monotonic() + (timeout or self.timeout)
        while True:
            msg = self._read_message(deadline)
            ptype = msg.get("payloadType")
            body = msg.get("payload") or {}
            if ptype == ERROR_RES and msg.get("clientMsgId") in (msg_id, None):
                raise CTraderError(body.get("errorCode", "UNKNOWN_ERROR"),
                                   body.get("description", ""))
            if ptype == HEARTBEAT_EVENT:
                continue
            matches_id = msg.get("clientMsgId") == msg_id
            matches_type = expect is not None and ptype == expect
            if matches_id or (matches_type and msg.get("clientMsgId") is None):
                if expect is not None and ptype != expect:
                    raise CTraderError("UNEXPECTED_RESPONSE",
                                       f"wanted payloadType {expect}, got {ptype}")
                return body
            self.events.append(msg)
            if len(self.events) > 500:
                del self.events[:-200]

    # --------------------------------------------------------------- calls
    def application_auth(self, client_id, client_secret):
        return self.request(APPLICATION_AUTH_REQ,
                            {"clientId": client_id, "clientSecret": client_secret},
                            expect=APPLICATION_AUTH_RES)

    def account_auth(self, account_id, access_token):
        return self.request(ACCOUNT_AUTH_REQ,
                            {"ctidTraderAccountId": int(account_id),
                             "accessToken": access_token},
                            expect=ACCOUNT_AUTH_RES)

    def account_list(self, access_token):
        body = self.request(GET_ACCOUNTS_BY_TOKEN_REQ, {"accessToken": access_token},
                            expect=GET_ACCOUNTS_BY_TOKEN_RES)
        return body.get("ctidTraderAccount", []) or []

    def trader(self, account_id):
        body = self.request(TRADER_REQ, {"ctidTraderAccountId": int(account_id)},
                            expect=TRADER_RES)
        return body.get("trader", {}) or {}

    def assets(self, account_id):
        body = self.request(ASSET_LIST_REQ, {"ctidTraderAccountId": int(account_id)},
                            expect=ASSET_LIST_RES)
        return body.get("asset", []) or []

    def symbols(self, account_id):
        body = self.request(SYMBOLS_LIST_REQ, {"ctidTraderAccountId": int(account_id)},
                            expect=SYMBOLS_LIST_RES)
        return body.get("symbol", []) or []

    def symbol_details(self, account_id, symbol_ids):
        if not symbol_ids:
            return []
        body = self.request(SYMBOL_BY_ID_REQ,
                            {"ctidTraderAccountId": int(account_id),
                             "symbolId": [int(s) for s in symbol_ids]},
                            expect=SYMBOL_BY_ID_RES)
        return body.get("symbol", []) or []

    def positions(self, account_id):
        body = self.request(RECONCILE_REQ, {"ctidTraderAccountId": int(account_id)},
                            expect=RECONCILE_RES)
        return body.get("position", []) or []

    def unrealized_pnl(self, account_id):
        """Returns (per-position list, moneyDigits)."""
        body = self.request(GET_POSITION_UNREALIZED_PNL_REQ,
                            {"ctidTraderAccountId": int(account_id)},
                            expect=GET_POSITION_UNREALIZED_PNL_RES)
        return body.get("positionUnrealizedPnL", []) or [], body.get("moneyDigits", 2)


# ------------------------------------------------------------------ OAuth
def _token_call(params):
    url = TOKEN_URL + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    # Spotware has shipped both a flat body and one nested under "payload".
    body = data.get("payload") if isinstance(data.get("payload"), dict) else data
    error = data.get("errorCode") or body.get("errorCode")
    if error:
        raise CTraderError(error, str(data.get("description")
                                      or body.get("description") or ""))
    if not body.get("accessToken"):
        raise CTraderError("NO_TOKEN", f"token endpoint returned: {data}")
    return body


def exchange_code(client_id, client_secret, code, redirect_uri):
    return _token_call({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "client_secret": client_secret,
    })


def refresh_token(client_id, client_secret, refresh):
    return _token_call({
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": client_id,
        "client_secret": client_secret,
    })


def authorization_url(client_id, redirect_uri, scope="accounts"):
    return AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "product": "web",
    })


# ------------------------------------------------------------------ config
CONFIG_PATH = os.path.expanduser("~/.config/omarchy/ctrader/config.json")
STATE_PATH = os.path.expanduser("~/.local/state/omarchy/ctrader/state.json")


def load_config(path=CONFIG_PATH):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def save_config(config, path=CONFIG_PATH):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def write_state(state, path=STATE_PATH):
    """Atomic replace so the shell's FileView never reads a half-written file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


# ----------------------------------------------------------------- history
# The snapshot in state.json is a single instant. To draw P/L over time the
# poller also keeps a durable log, because the widget's right-click "force
# update" restarts the unit — an in-memory series would be wiped every time
# the user reached for a refresh.
#
# Two files, deliberately: the log is append-only and cheap to write, while
# chart.json is a small pre-bucketed derivative the shell can re-parse on
# every tick without doing arithmetic over a week of samples in QML.
HISTORY_PATH = os.path.expanduser("~/.local/state/omarchy/ctrader/history.jsonl")
CHART_PATH = os.path.expanduser("~/.local/state/omarchy/ctrader/chart.json")

# A day of slack past the widest window, so the 7d chart is still full at the
# left edge right after a trim rather than starting a few minutes in.
HISTORY_RETENTION_SECONDS = 8 * 86400

# (key, span seconds, bucket seconds) — each spans ~56-72 buckets, which is
# about as many bars as fit legibly across the popup at its 420px width.
CHART_RANGES = (
    ("1h", 3600, 60),
    ("6h", 21600, 300),
    ("24h", 86400, 1200),
    ("7d", 604800, 10800),
)


def append_history(sample, path=HISTORY_PATH):
    """One line per tick. Append-only so a crash costs at most a torn line."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(sample, separators=(",", ":")) + "\n")


def load_history(path=HISTORY_PATH, retention=HISTORY_RETENTION_SECONDS, now=None):
    """Read the log back, dropping samples outside the retention window."""
    cutoff = (now if now is not None else time.time()) - retention
    samples = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    sample = json.loads(line)
                except ValueError:
                    continue  # a half-written final line from a hard kill
                ts = sample.get("t")
                if isinstance(ts, (int, float)) and ts >= cutoff:
                    samples.append(sample)
    except OSError:
        return []
    # Bucket "close" values depend on order, and a clock step backwards would
    # otherwise put an older sample last.
    samples.sort(key=lambda s: s["t"])
    return samples


def rewrite_history(samples, path=HISTORY_PATH):
    """Atomically replace the log with `samples` — how retention is applied."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for sample in samples:
            fh.write(json.dumps(sample, separators=(",", ":")) + "\n")
    os.replace(tmp, path)


def build_chart(samples, currency="", now=None):
    """Bucket the raw log into the fixed ranges the popup offers.

    Each point carries its bucket index rather than just a timestamp, so the
    UI can place bars on a real time axis. A gap then reads as a gap — if the
    machine was asleep for three hours the bars separate instead of closing
    up and implying continuous trading.
    """
    now = int(now if now is not None else time.time())
    ranges = {}
    # A week of retention is ~60k samples and this runs on every poll tick, so
    # each range seeks to its own start instead of walking the whole log four
    # times. The seek needs sorted timestamps; a clock step backwards can break
    # that between trims, so fall back to a full scan when it has.
    times = [int(s.get("t") or 0) for s in samples]
    seekable = all(times[i] <= times[i + 1] for i in range(len(times) - 1))
    for key, span, bucket_seconds in CHART_RANGES:
        start = now - span
        slots = span // bucket_seconds
        buckets = {}
        for sample in samples[bisect.bisect_left(times, start) if seekable else 0:]:
            ts = sample.get("t")
            if ts is None or ts < start or ts > now:
                continue
            index = min(slots - 1, int((ts - start) // bucket_seconds))
            net = float(sample.get("net") or 0.0)
            bucket = buckets.get(index)
            if bucket is None:
                buckets[index] = {"i": index,
                                  "t": start + index * bucket_seconds + bucket_seconds // 2,
                                  "net": net, "lo": net, "hi": net}
            else:
                # Last value wins: a bar is the bucket's close, with lo/hi
                # kept so a spike inside the bucket is not silently erased.
                bucket["net"] = net
                bucket["lo"] = min(bucket["lo"], net)
                bucket["hi"] = max(bucket["hi"], net)

        points = [buckets[i] for i in sorted(buckets)]
        # Zero is always in frame: a chart of only-losing bars still has to
        # show where break-even sits or the depth means nothing.
        lows = [p["lo"] for p in points] + [0.0]
        highs = [p["hi"] for p in points] + [0.0]
        for point in points:
            for field in ("net", "lo", "hi"):
                point[field] = round(point[field], 2)

        ranges[key] = {
            "span": span,
            "bucketSeconds": bucket_seconds,
            "slots": slots,
            "from": start,
            "to": now,
            "min": round(min(lows), 2),
            "max": round(max(highs), 2),
            "first": points[0]["net"] if points else 0.0,
            "last": points[-1]["net"] if points else 0.0,
            "points": points,
        }
    return {"updatedAt": now, "currency": currency,
            "ranges": ranges, "rangeKeys": [r[0] for r in CHART_RANGES]}


def write_chart(chart, path=CHART_PATH):
    """Atomic replace so the shell's FileView never reads a half-written file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(chart, fh, separators=(",", ":"))
        fh.write("\n")
    os.replace(tmp, path)
