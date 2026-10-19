.pragma library

// Pure formatting and parsing for the cTrader widget. Kept out of the QML
// so the bar pill and the portfolio popup format numbers identically.

var EMPTY = {
  status: "unconfigured",
  updatedAt: 0,
  error: "",
  environment: "",
  account: null,
  unrealized: null,
  positions: []
}

function parseState(text) {
  if (!text) return EMPTY
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return EMPTY
    return {
      status: parsed.status || "unknown",
      updatedAt: Number(parsed.updatedAt) || 0,
      error: parsed.error || "",
      environment: parsed.environment || "",
      account: parsed.account || null,
      unrealized: parsed.unrealized || null,
      positions: Array.isArray(parsed.positions) ? parsed.positions : []
    }
  } catch (e) {
    return EMPTY
  }
}

// Thousands separators, always two decimals — the shape a P/L column wants.
function money(value) {
  var n = Number(value)
  if (!isFinite(n)) return "—"
  var fixed = Math.abs(n).toFixed(2)
  var parts = fixed.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return (n < 0 ? "-" : "") + parts.join(".")
}

// The bar pill leads with the sign so a glance answers up-or-down before
// the eye reaches the digits.
function signedMoney(value) {
  var n = Number(value)
  if (!isFinite(n)) return "—"
  return (n > 0 ? "+" : "") + money(n)
}

// A dropped connection keeps showing the last known figure rather than an
// error glyph — the number is still the best answer available, and the colour
// dims to say it is no longer live.
function barLabel(state, showCurrency) {
  if (state.unrealized) {
    var text = signedMoney(state.unrealized.net)
    var code = showCurrency && state.unrealized.currency ? " " + state.unrealized.currency : ""
    return text + code
  }
  if (state.status === "unconfigured") return "P/L —"
  if (state.status === "error") return "P/L !"
  return "P/L …"
}

// Zero sits at neutral rather than green: a flat book is not a win.
function plColor(value, profitColor, lossColor, neutralColor) {
  var n = Number(value)
  if (!isFinite(n) || Math.abs(n) < 0.005) return neutralColor
  return n > 0 ? profitColor : lossColor
}

function formatPrice(price, digits) {
  var n = Number(price)
  if (!isFinite(n)) return "—"
  var d = Number(digits)
  return n.toFixed(isFinite(d) && d >= 0 && d <= 10 ? d : 5)
}

function formatLots(lots) {
  var n = Number(lots)
  if (!isFinite(n)) return "—"
  // Trim to the finest size a broker actually fills, then drop dead zeros.
  return n.toFixed(2).replace(/\.?0+$/, "") || "0"
}

function formatPct(value) {
  var n = Number(value)
  if (!isFinite(n)) return ""
  return (n > 0 ? "+" : "") + n.toFixed(2) + "%"
}

function ageSeconds(updatedAt, nowMs) {
  if (!updatedAt) return Number.MAX_VALUE
  return Math.max(0, Math.round(nowMs / 1000 - updatedAt))
}

function isStale(state, nowMs, staleAfter) {
  if (state.status === "error" || state.status === "connecting") return true
  if (state.status !== "ok") return false
  return ageSeconds(state.updatedAt, nowMs) > Math.max(5, Number(staleAfter) || 60)
}

function statusLine(state, nowMs) {
  switch (state.status) {
  case "unconfigured":
    return "Not connected — run ctrader-auth"
  case "connecting":
    return "Connecting to cTrader…"
  case "error":
    return state.error || "Connection error"
  case "ok":
    var age = ageSeconds(state.updatedAt, nowMs)
    if (age < 5) return "Live"
    if (age < 90) return "Updated " + age + "s ago"
    return "Stale — last update " + Math.round(age / 60) + "m ago"
  default:
    return "Waiting for data…"
  }
}

function openedAgo(openedAt, nowMs) {
  var ts = Number(openedAt)
  if (!isFinite(ts) || ts <= 0) return ""
  // cTrader timestamps are milliseconds since epoch.
  var mins = Math.max(0, Math.round((nowMs - ts) / 60000))
  if (mins < 60) return mins + "m"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + "h " + (mins % 60) + "m"
  return Math.floor(hours / 24) + "d " + (hours % 24) + "h"
}

// TradingView chart for a position. Many brokers list their CFDs (FX, metals,
// indices) on TradingView under their own exchange prefix, e.g. "BROKER:EURUSD";
// set the widget's tradingViewExchange to that prefix to open the broker's own
// feed. Left blank, the bare symbol lets TradingView pick a listing. Share CFDs
// ("TLT.US", "BHP.AU") open the underlying listing either way; a bare US
// ticker lets TradingView pick the primary exchange.
var SHARE_EXCHANGES = { US: "", AU: "ASX", UK: "LSE", DE: "XETR" }

function tradingViewSymbol(symbol, exchange) {
  var name = String(symbol || "").trim()
  if (!name || name.charAt(0) === "#") return ""
  var dot = name.lastIndexOf(".")
  if (dot > 0) {
    var suffix = name.slice(dot + 1).toUpperCase()
    if (SHARE_EXCHANGES.hasOwnProperty(suffix)) {
      var ticker = name.slice(0, dot).toUpperCase()
      var listing = SHARE_EXCHANGES[suffix]
      return listing ? listing + ":" + ticker : ticker
    }
  }
  var prefix = String(exchange || "").trim().toUpperCase()
  return prefix ? prefix + ":" + name.toUpperCase() : name.toUpperCase()
}

function tradingViewUrl(symbol, exchange) {
  var tv = tradingViewSymbol(symbol, exchange)
  if (!tv) return ""
  return "https://www.tradingview.com/chart/?symbol=" + encodeURIComponent(tv)
}

function totals(state) {
  var net = 0, swap = 0, commission = 0, margin = 0
  for (var i = 0; i < state.positions.length; i++) {
    var p = state.positions[i]
    net += Number(p.pnl) || 0
    swap += Number(p.swap) || 0
    commission += Number(p.commission) || 0
    margin += Number(p.usedMargin) || 0
  }
  return { net: net, swap: swap, commission: commission, margin: margin }
}

// ---------------------------------------------------------------- chart
// chart.json arrives pre-bucketed from the poller, so nothing here walks the
// raw sample log — these are pure geometry and label helpers.

var EMPTY_RANGE = {
  span: 0, bucketSeconds: 60, slots: 1, from: 0, to: 0,
  min: 0, max: 0, first: 0, last: 0, points: []
}

var EMPTY_CHART = { updatedAt: 0, currency: "", rangeKeys: ["1h", "6h", "24h", "7d"], ranges: {} }

function parseChart(text) {
  if (!text) return EMPTY_CHART
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return EMPTY_CHART
    return {
      updatedAt: Number(parsed.updatedAt) || 0,
      currency: parsed.currency || "",
      rangeKeys: Array.isArray(parsed.rangeKeys) ? parsed.rangeKeys : EMPTY_CHART.rangeKeys,
      ranges: parsed.ranges && typeof parsed.ranges === "object" ? parsed.ranges : {}
    }
  } catch (e) {
    return EMPTY_CHART
  }
}

function chartRange(chart, key) {
  var range = chart && chart.ranges ? chart.ranges[key] : null
  if (!range || !Array.isArray(range.points)) return EMPTY_RANGE
  return range
}

// The value axis. Zero always stays in frame — a window of nothing but losses
// still has to show where break-even sits or the depth reads as arbitrary.
function chartScale(range) {
  var lo = Math.min(0, Number(range.min) || 0)
  var hi = Math.max(0, Number(range.max) || 0)
  if (hi - lo < 0.02) { hi = 1; lo = -1 }  // a dead-flat book still needs an axis
  var pad = (hi - lo) * 0.08               // keep the tallest bar off the frame
  return { lo: lo - pad, hi: hi + pad }
}

function chartY(value, scale, height) {
  var span = scale.hi - scale.lo
  if (!(span > 0)) return height / 2
  var y = height * (scale.hi - Number(value)) / span
  return Math.max(0, Math.min(height, y))
}

// Bars are placed by bucket index rather than by position in the array, so an
// outage leaves a real hole instead of closing up and implying the poller was
// running the whole time.
function chartBarX(point, range, width) {
  var slots = Math.max(1, Number(range.slots) || 1)
  return width * (Number(point.i) || 0) / slots
}

function chartBarWidth(range, width) {
  var slots = Math.max(1, Number(range.slots) || 1)
  return Math.max(1, width / slots - 1)
}

function clockLabel(epochSeconds) {
  var d = new Date(Number(epochSeconds) * 1000)
  var h = d.getHours(), m = d.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

// "Fri 19" — the weekday alone would not do for a week-long window, where the
// first and last ticks land on the same day of the week.
function dateLabel(epochSeconds) {
  var d = new Date(Number(epochSeconds) * 1000)
  return WEEKDAYS[d.getDay()] + " " + d.getDate()
}

// A clock time answers "when" inside a day. Past that it stops doing so — four
// ticks across a week in HH:MM read as the same hour four times over — so the
// long windows label days instead.
function isMultiDay(range) {
  return (Number(range.span) || 0) > 36 * 3600
}

function tickLabel(epochSeconds, range) {
  return isMultiDay(range) ? dateLabel(epochSeconds) : clockLabel(epochSeconds)
}

// The hover readout has room for both, and on a 3h bucket the date alone would
// not say which part of the day the bar covers.
function pointLabel(point, range) {
  var t = Number(point.t)
  return isMultiDay(range) ? dateLabel(t) + " " + clockLabel(t) : clockLabel(t)
}

// Evenly spaced time ticks across the window, as {at: 0..1, label: "14:00"}.
function chartTicks(range, count) {
  var ticks = []
  var from = Number(range.from) || 0
  var to = Number(range.to) || 0
  if (to <= from) return ticks
  var n = Math.max(2, Number(count) || 4)
  for (var i = 0; i < n; i++) {
    var frac = i / (n - 1)
    ticks.push({ at: frac, label: tickLabel(from + (to - from) * frac, range) })
  }
  return ticks
}

function rangeTitle(key) {
  switch (key) {
  case "1h": return "Last hour"
  case "6h": return "Last 6 hours"
  case "24h": return "Last 24 hours"
  case "7d": return "Last 7 days"
  default: return key
  }
}

// How much of the window actually has data. Drives the "still collecting"
// note, so an almost-empty 24h chart explains itself rather than looking broken.
function chartCoverage(range) {
  var slots = Math.max(1, Number(range.slots) || 1)
  var points = Array.isArray(range.points) ? range.points : []
  if (!points.length) return 0
  var first = Number(points[0].i) || 0
  return (slots - first) / slots
}

// Change across the window: what the graph is actually there to answer.
function chartDelta(range) {
  var points = Array.isArray(range.points) ? range.points : []
  if (points.length < 2) return null
  return Number(points[points.length - 1].net) - Number(points[0].net)
}

function chartSummary(range, nowMs) {
  var points = Array.isArray(range.points) ? range.points : []
  if (!points.length) return "No samples in this window yet"
  var delta = chartDelta(range)
  if (delta === null) return "Collecting — one sample so far"
  var spanMins = Math.round(((Number(points[points.length - 1].t) - Number(points[0].t)) || 0) / 60)
  var over = spanMins >= 2880 ? Math.round(spanMins / 1440) + "d"
           : spanMins >= 120 ? Math.round(spanMins / 60) + "h"
           : spanMins >= 1 ? spanMins + "m"
           : "under a minute"
  return signedMoney(delta) + " over " + over
}

// Nearest bucket to a 0..1 position across the plot, for the hover readout.
// Returns null when the pointer sits in a gap rather than snapping the label
// across an outage to a bar that is nowhere near the cursor.
function chartPointAt(range, frac) {
  var points = Array.isArray(range.points) ? range.points : []
  if (!points.length) return null
  var slots = Math.max(1, Number(range.slots) || 1)
  var target = frac * slots
  var best = null
  var bestDist = Infinity
  for (var i = 0; i < points.length; i++) {
    var dist = Math.abs((Number(points[i].i) || 0) + 0.5 - target)
    if (dist < bestDist) { bestDist = dist; best = points[i] }
  }
  return bestDist > slots * 0.04 + 1 ? null : best
}

// Value-axis marks: the window's peak, break-even and trough. Labelling the
// padded frame bounds instead would put a number on the axis that no sample
// ever hit — the padding exists to keep bars off the edge, not to be read.
// Marks that would overprint once mapped to pixels are dropped, peak and
// trough winning over zero.
function axisMarks(range, scale, height) {
  var wanted = []
  var max = Number(range.max) || 0
  var min = Number(range.min) || 0
  wanted.push({ value: max, label: signedMoney(max), muted: false })
  if (min < -0.005) wanted.push({ value: min, label: signedMoney(min), muted: false })
  wanted.push({ value: 0, label: "0", muted: true })

  var kept = []
  for (var i = 0; i < wanted.length; i++) {
    var y = chartY(wanted[i].value, scale, height)
    var clash = false
    for (var j = 0; j < kept.length; j++) {
      if (Math.abs(kept[j].y - y) < 12) { clash = true; break }
    }
    if (!clash) {
      wanted[i].y = y
      kept.push(wanted[i])
    }
  }
  return kept
}
