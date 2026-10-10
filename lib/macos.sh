# shellcheck shell=bash
# macOS layer for vpnc: Homebrew deps, launchd daemon, no per-user routing.
# Implements the os_* interface used by lib/common.sh.
#
# Not available on macOS (by design): "only selected users" mode (needs
# nftables + ip rule) and mihomo tun auto-redirect (Linux-only). Use the
# process_name rules (`vpnc rules edit`) to route individual apps instead.

OS_NAME_RELEASE="darwin"         # asset name in mihomo releases
OS_DEFAULT_CLASH_BIND="127.0.0.1:9090"
OS_AUTO_REDIRECT="false"
OS_TUN_INTERFACE=""              # macOS requires utunN; let mihomo pick one

LAUNCHD_LABEL="com.makrelbka.vpnc.mihomo"
SERVICE_FILE="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
SERVICE_LOG="/var/log/mihomo.log"

# Left behind by the sing-box version of vpnc (see os_migrate_from_singbox).
OLD_LAUNCHD_LABEL="com.makrelbka.vpnc.sing-box"
OLD_SUBSCRIPTION_LABEL="com.makrelbka.vpnc.subscription-refresh"

os_service_file() {
  echo "$SERVICE_FILE"
}

os_selected_users_supported() {
  return 1
}

os_ensure_deps() {
  local missing_cmds=()
  local brew_pkgs=()
  local cmd

  for cmd in curl jq tar install mktemp sed grep id base64 launchctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    fi
  done

  if (( ${#missing_cmds[@]} == 0 )); then
    return
  fi

  warn "Missing dependencies: ${missing_cmds[*]}"

  for cmd in "${missing_cmds[@]}"; do
    case "$cmd" in
      jq|curl) brew_pkgs+=("$cmd") ;;
      *) die "Required system tool is missing: $cmd (it ships with macOS, something is off with PATH)" ;;
    esac
  done

  local brew_bin
  brew_bin="$(command -v brew || true)"
  [[ -n "$brew_bin" ]] || die "Homebrew is required to install: ${brew_pkgs[*]} (https://brew.sh)"

  # Homebrew refuses to run as root; drop back to the invoking user if we are root.
  if [[ "${EUID}" -eq 0 ]]; then
    [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
      || die "Homebrew cannot run as root. Install manually: brew install ${brew_pkgs[*]}"
    sudo -u "$SUDO_USER" "$brew_bin" install "${brew_pkgs[@]}"
  else
    "$brew_bin" install "${brew_pkgs[@]}"
  fi
}

os_check_cmds() {
  ensure_cmd launchctl
}

write_service_file() {
  local tmp_plist
  tmp_plist="$(mktemp)"

  cat > "$tmp_plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${MIHOMO_BIN}</string>
    <string>-d</string>
    <string>${CONFIG_DIR}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>3</integer>
  <key>StandardOutPath</key>
  <string>${SERVICE_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${SERVICE_LOG}</string>
</dict>
</plist>
PLIST_EOF

  run_root install -d -m 0755 "$(dirname "$SERVICE_FILE")"
  run_root install -m 0644 "$tmp_plist" "$SERVICE_FILE"
  run_root chown root:wheel "$SERVICE_FILE"
  rm -f "$tmp_plist"
}

# The sing-box version of vpnc ran its own TUN and a refresh job; both would fight the
# new daemon, so they are unloaded and removed (the /etc/sing-box files stay untouched).
os_migrate_from_singbox() {
  local label
  for label in "$OLD_LAUNCHD_LABEL" "$OLD_SUBSCRIPTION_LABEL"; do
    run_root launchctl bootout "system/${label}" 2>/dev/null || true
    run_root rm -f "/Library/LaunchDaemons/${label}.plist"
  done
  run_root rm -f /var/log/sing-box.log /var/log/vpnc-subscription.log
}

os_service_write() {
  os_migrate_from_singbox
  write_service_file
}

_launchd_loaded() {
  local label="${1:-$LAUNCHD_LABEL}"
  run_root launchctl print "system/${label}" >/dev/null 2>&1
}

# `launchctl bootout` returns before the daemon has fully stopped (mihomo tears its TUN
# down first), and a `bootstrap` issued in that window fails with "Input/output error"
# (5), leaving the service unloaded. So: wait for the unload, then retry the bootstrap.
_launchd_wait_unloaded() {
  local label="${1:-$LAUNCHD_LABEL}" i
  for i in $(seq 1 30); do
    _launchd_loaded "$label" || return 0
    sleep 0.5
  done
  return 1
}

_launchd_bootstrap() {
  local plist="$1" label="$2" i
  for i in 1 2 3 4 5; do
    if run_root launchctl bootstrap system "$plist" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  if launchctl print-disabled system 2>/dev/null | grep -q "\"${label}\" => disabled"; then
    die "Service ${label} is disabled in launchd (autostart off). Run: $(basename "$0") enable"
  fi

  # Last attempt, this time letting launchctl show the real error.
  run_root launchctl bootstrap system "$plist" \
    || die "Could not load ${label}. Inspect: sudo launchctl print system/${label}"
}

# launchd re-reads the plist on bootstrap, so there is nothing to reload here.
os_service_reload() {
  return 0
}

os_service_enable() {
  run_root launchctl enable "system/${LAUNCHD_LABEL}"
}

os_service_disable() {
  run_root launchctl disable "system/${LAUNCHD_LABEL}"
}

os_service_start() {
  if _launchd_loaded; then
    run_root launchctl kickstart "system/${LAUNCHD_LABEL}"
  else
    _launchd_bootstrap "$SERVICE_FILE" "$LAUNCHD_LABEL"
  fi
}

# On macOS "stop" unloads the daemon (KeepAlive would otherwise restart it).
os_service_stop() {
  run_root launchctl bootout "system/${LAUNCHD_LABEL}"
}

os_service_restart() {
  run_root launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  _launchd_wait_unloaded "$LAUNCHD_LABEL" || warn "Service is slow to stop, trying to start it anyway"
  _launchd_bootstrap "$SERVICE_FILE" "$LAUNCHD_LABEL"
}

os_service_is_active() {
  run_root launchctl print "system/${LAUNCHD_LABEL}" 2>/dev/null | grep -q 'state = running'
}

os_service_status() {
  if _launchd_loaded; then
    run_root launchctl print "system/${LAUNCHD_LABEL}" 2>&1 | sed -n '1,25p'
  else
    echo "Service ${LAUNCHD_LABEL} is not loaded (start it with: $(basename "$0") start)"
  fi
}

os_service_logs() {
  run_root tail -n 100 -F "$SERVICE_LOG"
}

os_service_remove() {
  run_root launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  run_root rm -f "$SERVICE_FILE" "$SERVICE_LOG"
}

# Per-user routing is Linux-only: keep the shared code paths as no-ops.
clear_selected_routing() { :; }
clear_legacy_sing_box_routing() { :; }
remove_custom_nft_files() { :; }
apply_selected_routing_from_state() { :; }
