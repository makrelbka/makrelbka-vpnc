# singbox-bootstrap

Interactive installer for `sing-box` with service management.

## What it does

- installs `sing-box` binary from official GitHub release;
- installs helper command `makrelbka-vpnc`;
- asks VPN type:
  - `VLESS`
  - `VLESS + REALITY`
- asks input format:
  - `vless://` URL
  - JSON config
- converts input into `/etc/sing-box/config.json`;
- enables full-tunnel mode (all traffic through VPN) via TUN + route rules;
- creates/updates `systemd` service `sing-box.service`;
- enables service autostart and restarts it.

Default installed `sing-box` version is `1.12.0` (stable with this config format).

## One-line run (after you publish to GitHub)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/<your-user>/<your-repo>/main/singbox-bootstrap/install.sh)
```

## Optional run without immediate interactive setup

```bash
bash <(curl -Ls https://raw.githubusercontent.com/<your-user>/<your-repo>/main/singbox-bootstrap/install.sh) --no-configure
```

## Service / VPN management

```bash
makrelbka-vpnc configure
makrelbka-vpnc reconfigure
makrelbka-vpnc status
makrelbka-vpnc start
makrelbka-vpnc stop
makrelbka-vpnc restart
makrelbka-vpnc logs
makrelbka-vpnc show-config
```
