# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Reporting a bug

Open an issue using the **Bug report** template. Include the output of
`ctrader-poll --once --print` and any errors from
`journalctl --user -u omarchy-ctrader.service`. **Redact first**: remove your
account ID, client ID, client secret and any `accessToken` or `refreshToken`.
Never paste `~/.config/omarchy/ctrader/config.json`.

Security problems go through [SECURITY.md](SECURITY.md), not a public issue.

## Proposing a change

1. Fork the repo and create a branch from `main`.
2. Make your change. See **Development** in the [README](README.md) for the
   reload rules (`Model.js` needs a shell restart; `bin/` changes need a
   service restart).
3. Check it:

   ```bash
   omarchy plugin validate .
   python3 -m py_compile bin/ctrader.py bin/ctrader-auth bin/ctrader-poll
   bash -n setup
   ```

4. Test against a **demo** account.
5. Open a pull request against `main` and fill in the template.

`main` is protected: every change lands through a reviewed pull request.

## Ground rules

- **Read-only, always.** The plugin requests the `accounts` scope and never
  sends an order message. Pull requests that add trading actions will not be
  merged.
- **Standard library only.** No `pip` dependencies in `bin/`.
- **No broker-specific behaviour by default.** It must work with any cTrader
  broker. Broker-specific behaviour belongs behind a setting.
- **No credentials in the repo**, not even example ones that look real.
- Match the style of the surrounding code, and keep comments about *why*.
