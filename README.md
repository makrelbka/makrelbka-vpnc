# singbox-bootstrap

Interactive installer for `sing-box` with service management.

## What it does

- installs `sing-box` binary from official GitHub release;
- installs helper command `makrelbka-vpnc`;
- installs helper alias `vpnc`;
- checks required runtime tools and installs missing packages automatically when possible;
- asks input format:
  - `vless://` / `ss://` URL — single server
  - JSON config — single server (VLESS-style)
  - subscription URL — multiple servers, grouped into a selector + auto (lowest-latency) outbound
- for a single server, asks VPN type:
  - `VLESS`
  - `VLESS + REALITY`
- asks whether to enable the optional web dashboard (Clash-compatible UI) and, if so, its bind address;
- converts input into `/etc/sing-box/config.json`;
- supports full-tunnel mode or selected-users mode via TUN + route rules (single-server mode only; subscriptions are always full-tunnel);
- supports a separate direct-vs-VPN rules file (`vpnc rules ...`, starts empty, optionally seedable from a local/remote JSON file) for bypassing specific domains/IPs/processes/ports;
- creates/updates `systemd` service `sing-box.service`;
- enables service autostart and restarts it.

Default installed `sing-box` version is `1.12.20`.

## Protocol support

URL input supports:

- `vless://`
- `ss://`

JSON input is still intended for VLESS-style configs.

## Supported systems

Primary target:
- Debian
- Ubuntu

The installer detects missing packages and tries to install them automatically.

For Debian / Ubuntu it installs what is needed for normal work:
- `curl`
- `ca-certificates`
- `jq`
- `tar`
- `nftables`
- `iproute2`
- `systemd`
- `findutils`

## One-line run (after you publish to GitHub)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makrelbka/makrelbka-vpnc/main/install.sh)

```

## Optional run without immediate interactive setup

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makrelbka/makrelbka-vpnc/main/install.sh) --no-configure
```

## Updating an existing device

If the device already has `vpnc` / `makrelbka-vpnc` installed and you only need the newer manager logic:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/makrelbka/makrelbka-vpnc/main/install.sh) --no-configure
vpnc reconfigure
```

For a local checkout, the same can be done with:

```bash
bash ./install.sh --no-configure
vpnc reconfigure
```

When reconfiguring with the new version, pick the input format that matches what you have:

- `VPN URL` — paste either `vless://...` or `ss://...`
- `JSON config` — paste a VLESS-style JSON
- `Subscription URL` — paste a subscription link (see [Subscription mode](#subscription-mode))

Either way you'll also be asked whether to turn on the web dashboard — see [Web dashboard](#web-dashboard).

## What gets checked automatically

On install:
- download tools and bootstrap packages
- `nftables`
- `iproute2`
- `systemd`

At runtime:
- `jq`
- `nft`
- `ip`
- `curl`
- `systemctl`
- `journalctl`

If a required dependency is missing and the package manager is available, the script tries to install it automatically.

The installer also normalizes `PATH` for regular users and includes common `sbin` directories, so tools like `nft` work correctly on Debian/Ubuntu even when they are installed under `/usr/sbin`.

## Service / VPN management

```bash
vpnc configure
vpnc reconfigure
vpnc subscribe [url]
vpnc rules {edit|list|toggle|apply}
vpnc status
vpnc start
vpnc stop
vpnc restart
vpnc logs
vpnc show-config
```

(`makrelbka-vpnc` still works as a compatibility alias for all of the above.)

## Subscription mode

`vpnc configure` / `vpnc reconfigure` now offer a third input format — "Subscription URL" —
alongside the single-server `vless://`/`ss://`/JSON options. Pick it and paste a subscription
link (plain `vless://`/`ss://` lines or a base64 blob of them, one server per line, `#name`
fragment used as display name) to pull in every server it lists, instead of just one.

For refreshing (or first-time scripted setup) without going through the interactive menu,
there's also a standalone command:

```bash
vpnc subscribe https://your-subscription-url
```

Every entry becomes a sing-box outbound (reusing the same parser as `configure`), grouped
into:
- a `selector` outbound (`proxy`) — manual pick, one server or `auto`
- a `urltest` outbound (`auto`) — automatically follows the lowest-latency server

Re-run without a URL to refresh the previously saved subscription (this reuses whatever
dashboard on/off choice was made when the subscription was first set up, so refreshing is
non-interactive):

```bash
vpnc subscribe
```

Subscription mode is always full-tunnel (selected-users UID mode is not combined with it).

## Web dashboard

Both single-server and subscription configs can optionally turn on sing-box's built-in
Clash-compatible dashboard (`experimental.clash_api` + `external_ui`, auto-downloading
[metacubexd](https://github.com/MetaCubeX/metacubexd)). It is **off by default** — `configure`
/ `reconfigure` / a first-time `subscribe <url>` always ask "Enable web dashboard?" and the
dashboard is only wired into `config.json` if you answer yes. There is no way to end up with
it enabled without explicitly choosing it at one of those points (refreshing an existing
subscription with `vpnc subscribe` just carries the previous answer forward, it never flips
it on by itself).

If you say yes, you're also asked for the **bind address** (`IP:port`) to serve it on —
press Enter to accept the suggested default (`192.168.77.2:9090`, the Wi-Fi hotspot's own
address, see `wifi-hotspot-vpnc`, so the dashboard is reachable only from devices connected
to that Wi-Fi network) or type your own. The suggested default itself can be changed with
the `VPNC_CLASH_API_BIND` env var before running `configure`/`subscribe`. Once enabled, it's
served at:

```
http://<chosen-bind>/ui/
```

From the dashboard you get, per server: latency ping, throughput/speed test, manual
selection, and (in subscription mode) the `auto` (fastest) group — no extra tooling needed.
`vpnc status` shows whether the dashboard is currently enabled and its URL.

## Direct-vs-VPN rules

A separate rules file controls which domains/processes/ports/IPs bypass the VPN
(`outbound: "direct"`), independent of whether you're on `configure` or `subscribe` mode:

```bash
vpnc rules edit             # opens $EDITOR (default: nano) on the rules JSON
vpnc rules list              # show rule groups and on/off state
vpnc rules toggle <name> on|off   # flip a group without opening the editor
vpnc rules apply             # recompile into sing-box route.rules + restart
```

Each rule group looks like:

```json
{
  "outbound": "direct",
  "name": "Local networks",
  "switch": true,
  "or": true,
  "ip_cidr": ["192.168.0.0/16", "10.0.0.0/8"]
}
```

Supported condition fields: `domain`, `domain_suffix`, `domain_keyword`, `domain_regex`,
`ip_cidr`, `port`, `port_range`, `process_name`, `package_name`. `switch: false` disables a
group without deleting it. `or: true` combines multiple condition fields in the same group
with OR logic (sing-box's `logical` rule type); otherwise they combine with AND, matching
sing-box's own default.

The rules file ships **empty** — there is no built-in default rule set, so nothing bypasses
the VPN until you add rule groups yourself. You can build it up interactively with
`vpnc rules edit`/`rules toggle`, or seed it in one shot from a JSON file
(`{"rules": [...]}`, same shape as the rule group example above) by setting one of these env
vars before the first `rules` command runs on the box:

```bash
VPNC_RULES_SEED_PATH=/path/to/rules.json vpnc rules list   # local file
VPNC_RULES_SEED_URL=https://example.com/rules.json vpnc rules list   # remote file
```

Both are optional and only consulted once, when `$RULES_FILE` doesn't exist yet — leave them
unset to skip seeding and start from an empty file. This repo's own `vpnc-rules.local.json`
(if you keep one) is git-ignored on purpose: personal rule sets tend to contain your
employer's/bank's domains and shouldn't be committed — point `VPNC_RULES_SEED_PATH` at it
locally, or copy it to the target box, instead.

Note: `process_name`/`port` conditions only match traffic that originates on the box
running `sing-box` itself — for a router/hotspot setup they mostly matter for traffic from
the box itself, not from Wi-Fi clients. `domain_suffix`/`domain_keyword`/`ip_cidr`
conditions work normally for all forwarded (hotspot client) traffic.

## Notes

- The service waits for `sbtun` before applying selected-user routing, so the old `Cannot find device "sbtun"` startup race is handled.
- On Debian / Ubuntu you usually do not need to install libraries or networking tools manually before running the installer.
