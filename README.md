# singbox-bootstrap

Interactive installer for `sing-box` with service management.

## What it does

- installs `sing-box` binary from official GitHub release;
- installs helper command `makrelbka-vpnc`;
- installs helper alias `vpnc`;
- checks required runtime tools and installs missing packages automatically when possible;
- asks VPN type:
  - `VLESS`
  - `VLESS + REALITY`
- asks input format:
  - `vless://` URL
  - JSON config
- converts input into `/etc/sing-box/config.json`;
- supports full-tunnel mode or selected-users mode via TUN + route rules;
- creates/updates `systemd` service `sing-box.service`;
- enables service autostart and restarts it.

Default installed `sing-box` version is `1.12.20`.

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
makrelbka-vpnc configure
makrelbka-vpnc reconfigure
makrelbka-vpnc status
makrelbka-vpnc start
makrelbka-vpnc stop
makrelbka-vpnc restart
makrelbka-vpnc logs
makrelbka-vpnc show-config
```

### or

```bash
vpnc configure
vpnc reconfigure
vpnc status
vpnc start
vpnc stop
vpnc restart
vpnc logs
vpnc show-config
```

## Notes

- The service waits for `sbtun` before applying selected-user routing, so the old `Cannot find device "sbtun"` startup race is handled.
- On Debian / Ubuntu you usually do not need to install libraries or networking tools manually before running the installer.
