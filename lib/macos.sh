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
OS_CONTROL_FILE_GROUP="admin"     # control.json readable by admin users (the Mac owner)
OS_TUN_INTERFACE=""              # macOS requires utunN; let mihomo pick one

LAUNCHD_LABEL="com.makrelbka.vpnc.mihomo"
SERVICE_FILE="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
SERVICE_LOG="/var/log/mihomo.log"
GUARD_LABEL="com.makrelbka.vpnc.guard"   # failover guard (lib/guard.sh), a second daemon next to mihomo
GUARD_SERVICE_FILE="/Library/LaunchDaemons/${GUARD_LABEL}.plist"
GUARD_LOG="/var/log/vpnc-guard.log"

# Physical interface of the default route (the TUN only adds split routes on top of it).
os_default_iface() {
  route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}'
}

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
  write_guard_service_file
}

write_guard_service_file() {
  local tmp_plist
  tmp_plist="$(mktemp)"
  cat > "$tmp_plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${GUARD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/vpnc</string>
    <string>_guard</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>${GUARD_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${GUARD_LOG}</string>
</dict>
</plist>
PLIST_EOF
  run_root install -m 0644 "$tmp_plist" "$GUARD_SERVICE_FILE"
  run_root chown root:wheel "$GUARD_SERVICE_FILE"
  rm -f "$tmp_plist"
}

# The guard never blocks the mihomo service commands: its failures are only warnings.
guard_service_start() {
  _launchd_loaded "$GUARD_LABEL" && return 0
  run_root launchctl bootstrap system "$GUARD_SERVICE_FILE" 2>/dev/null \
    || warn "Could not load the failover guard (${GUARD_LABEL}); priority server will not fail over"
}

guard_service_stop() {
  run_root launchctl bootout "system/${GUARD_LABEL}" 2>/dev/null || true
}

os_service_write() {
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
  run_root launchctl enable "system/${GUARD_LABEL}" 2>/dev/null || true
}

os_service_disable() {
  run_root launchctl disable "system/${LAUNCHD_LABEL}"
  run_root launchctl disable "system/${GUARD_LABEL}" 2>/dev/null || true
}

os_service_start() {
  if _launchd_loaded; then
    run_root launchctl kickstart "system/${LAUNCHD_LABEL}"
  else
    _launchd_bootstrap "$SERVICE_FILE" "$LAUNCHD_LABEL"
  fi
  guard_service_start
}

# On macOS "stop" unloads the daemon (KeepAlive would otherwise restart it).
os_service_stop() {
  guard_service_stop
  run_root launchctl bootout "system/${LAUNCHD_LABEL}"
}

os_service_restart() {
  run_root launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  _launchd_wait_unloaded "$LAUNCHD_LABEL" || warn "Service is slow to stop, trying to start it anyway"
  _launchd_bootstrap "$SERVICE_FILE" "$LAUNCHD_LABEL"
  guard_service_stop   # reload the plist: it may have changed since the guard was loaded
  guard_service_start
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
  guard_service_stop
  run_root launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  run_root rm -f "$SERVICE_FILE" "$SERVICE_LOG" "$GUARD_SERVICE_FILE" "$GUARD_LOG"
}

# Per-user routing is Linux-only: keep the shared code paths as no-ops.
clear_selected_routing() { :; }
clear_legacy_sing_box_routing() { :; }
remove_custom_nft_files() { :; }
apply_selected_routing_from_state() { :; }
