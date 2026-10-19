# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them
privately through GitHub instead: **Security** tab → **Report a vulnerability**.

Useful details include the affected file and version, steps to reproduce, and
the impact you expect. You should get a response within a week.

## Scope

Things worth reporting include:

- anything that could leak a user's Client secret or OAuth tokens
- anything that could let the plugin place, modify or close a trade
- weaknesses in the OAuth callback listener (`ctrader-auth`) or the systemd
  sandbox (`systemd/omarchy-ctrader.service`)

## Your credentials

This plugin never sends your credentials anywhere except the cTrader Open API.
They are stored only in `~/.config/omarchy/ctrader/config.json` (mode `0600`).
If you think your Client secret or tokens were exposed, revoke them at
<https://openapi.ctrader.com/> and run `ctrader-auth` again.
