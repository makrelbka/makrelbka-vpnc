# shellcheck shell=bash
# macOS layer for vpnc: Homebrew deps, launchd daemon, no per-user routing.
# Implements the os_* interface used by lib/common.sh.
#
# Not available on macOS (by design): "only selected users" mode (needs
# nftables + ip rule) and sing-box auto_redirect (Linux-only). Use the
# process_name rules (`vpnc rules edit`) to route individual apps instead.

OS_NAME_RELEASE="darwin"         # asset name in sing-box releases
OS_DEFAULT_CLASH_BIND="127.0.0.1:9090"
OS_AUTO_REDIRECT="false"
OS_TUN_INTERFACE=""              # macOS requires utunN; let sing-box pick one

LAUNCHD_LABEL="com.makrelbka.vpnc.sing-box"
SERVICE_FILE="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
SERVICE_LOG="/var/log/sing-box.log"

SUBSCRIPTION_LAUNCHD_LABEL="com.makrelbka.vpnc.subscription-refresh"
SUBSCRIPTION_SERVICE_FILE="/Library/LaunchDaemons/${SUBSCRIPTION_LAUNCHD_LABEL}.plist"
SUBSCRIPTION_LOG="/var/log/vpnc-subscription.log"

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
    <string>/usr/local/bin/sing-box</string>
    <string>run</string>
    <string>-c</string>
    <string>${CONFIG_FILE}</string>
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

os_service_write() {
  write_service_file
}

_launchd_loaded() {
  local label="${1:-$LAUNCHD_LABEL}"
  run_root launchctl print "system/${label}" >/dev/null 2>&1
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
    run_root launchctl bootstrap system "$SERVICE_FILE" \
      || die "Could not load the service. If autostart was disabled, run: $(basename "$0") enable"
  fi
}

# On macOS "stop" unloads the daemon (KeepAlive would otherwise restart it).
os_service_stop() {
  run_root launchctl bootout "system/${LAUNCHD_LABEL}"
}

os_service_restart() {
  run_root launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  run_root launchctl bootstrap system "$SERVICE_FILE" \
    || die "Could not load the service. If autostart was disabled, run: $(basename "$0") enable"
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

# --- subscription auto-refresh (launchd StartInterval) ----------------------

os_subscription_timer_write() {
  local interval_sec="$1"
  local tmp_plist
  tmp_plist="$(mktemp)"

  cat > "$tmp_plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SUBSCRIPTION_LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/vpnc</string>
    <string>subscribe</string>
  </array>
  <key>StartInterval</key>
  <integer>${interval_sec}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${SUBSCRIPTION_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${SUBSCRIPTION_LOG}</string>
</dict>
</plist>
PLIST_EOF

  run_root install -d -m 0755 "$(dirname "$SUBSCRIPTION_SERVICE_FILE")"
  run_root install -m 0644 "$tmp_plist" "$SUBSCRIPTION_SERVICE_FILE"
  run_root chown root:wheel "$SUBSCRIPTION_SERVICE_FILE"
  rm -f "$tmp_plist"
}

os_subscription_timer_enable() {
  if _launchd_loaded "$SUBSCRIPTION_LAUNCHD_LABEL"; then
    run_root launchctl bootout "system/${SUBSCRIPTION_LAUNCHD_LABEL}" 2>/dev/null || true
  fi
  run_root launchctl enable "system/${SUBSCRIPTION_LAUNCHD_LABEL}" 2>/dev/null || true
  run_root launchctl bootstrap system "$SUBSCRIPTION_SERVICE_FILE"
}

os_subscription_timer_disable() {
  run_root launchctl bootout "system/${SUBSCRIPTION_LAUNCHD_LABEL}" 2>/dev/null || true
}

os_subscription_timer_remove() {
  os_subscription_timer_disable
  run_root rm -f "$SUBSCRIPTION_SERVICE_FILE" "$SUBSCRIPTION_LOG"
}

os_subscription_timer_status() {
  if _launchd_loaded "$SUBSCRIPTION_LAUNCHD_LABEL"; then
    echo "on, every ${SUBSCRIPTION_REFRESH_SEC}s"
  else
    echo "off"
  fi
}

# Per-user routing is Linux-only: keep the shared code paths as no-ops.
clear_selected_routing() { :; }
clear_legacy_sing_box_routing() { :; }
remove_custom_nft_files() { :; }
apply_selected_routing_from_state() { :; }
