# shellcheck shell=bash
# Linux layer for vpnc: package managers, systemd service, nftables/ip-rule
# selected-users routing. Implements the os_* interface used by lib/common.sh.

OS_NAME_RELEASE="linux"          # asset name in sing-box releases
OS_DEFAULT_CLASH_BIND="192.168.77.2:9090"   # the Wi-Fi hotspot's own address (wlan0-ap.service)
OS_AUTO_REDIRECT="true"          # sing-box auto_redirect is Linux-only (needs nftables)
OS_TUN_INTERFACE="sbtun"

SERVICE_FILE="/etc/systemd/system/sing-box.service"
SUBSCRIPTION_TIMER_UNIT="vpnc-subscription.timer"
SUBSCRIPTION_SERVICE_UNIT="vpnc-subscription.service"
SUBSCRIPTION_TIMER_FILE="/etc/systemd/system/${SUBSCRIPTION_TIMER_UNIT}"
SUBSCRIPTION_SERVICE_FILE="/etc/systemd/system/${SUBSCRIPTION_SERVICE_UNIT}"

os_service_file() {
  echo "$SERVICE_FILE"
}

os_selected_users_supported() {
  return 0
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update -y
    run_root apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y "$@"
  elif command -v pacman >/dev/null 2>&1; then
    run_root pacman -Sy --noconfirm "$@"
  elif command -v zypper >/dev/null 2>&1; then
    run_root zypper --non-interactive install "$@"
  elif command -v apk >/dev/null 2>&1; then
    run_root apk add --no-cache "$@"
  else
    die "Unsupported package manager. Install required runtime dependencies manually."
  fi
}

os_ensure_deps() {
  local missing_cmds=()
  local cmd

  for cmd in curl jq tar nft ip systemctl journalctl find install mktemp sed grep id base64; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    fi
  done

  if (( ${#missing_cmds[@]} == 0 )); then
    return
  fi

  warn "Missing dependencies: ${missing_cmds[*]}"

  if command -v apt-get >/dev/null 2>&1; then
    install_packages curl ca-certificates jq tar nftables iproute2 systemd findutils coreutils grep sed util-linux
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    install_packages curl ca-certificates jq tar nftables iproute systemd findutils coreutils grep sed util-linux
  elif command -v pacman >/dev/null 2>&1; then
    install_packages curl ca-certificates jq tar nftables iproute2 systemd findutils coreutils grep sed util-linux
  elif command -v zypper >/dev/null 2>&1; then
    install_packages curl ca-certificates jq tar nftables iproute2 systemd findutils coreutils grep sed util-linux
  elif command -v apk >/dev/null 2>&1; then
    install_packages curl ca-certificates jq tar nftables iproute2 findutils coreutils grep sed util-linux
  else
    die "Unsupported package manager. Install dependencies manually: ${missing_cmds[*]}"
  fi
}

os_check_cmds() {
  ensure_cmd systemctl nft ip
}

wait_for_interface() {
  local ifname="$1"
  local timeout="${2:-15}"
  local i

  for i in $(seq 1 "$timeout"); do
    if run_root ip link show "$ifname" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

write_service_file() {
  if [[ -n "$SUDO" ]]; then
    $SUDO tee "$SERVICE_FILE" >/dev/null <<'UNIT_EOF'
[Unit]
Description=sing-box
After=network-online.target wlan0-ap.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecStartPost=/usr/local/bin/vpnc _apply-selected-routing
ExecStopPost=-/usr/local/bin/vpnc _clear-selected-routing
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_EOF
  else
    cat > "$SERVICE_FILE" <<'UNIT_EOF'
[Unit]
Description=sing-box
After=network-online.target wlan0-ap.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecStartPost=/usr/local/bin/vpnc _apply-selected-routing
ExecStopPost=-/usr/local/bin/vpnc _clear-selected-routing
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_EOF
  fi
}

os_service_write() {
  write_service_file
}

os_service_reload() {
  run_root systemctl daemon-reload
}

os_service_enable() {
  run_root systemctl enable sing-box
}

os_service_disable() {
  run_root systemctl disable sing-box
}

os_service_start() {
  run_root systemctl start sing-box
}

os_service_stop() {
  run_root systemctl stop sing-box
}

os_service_restart() {
  run_root systemctl restart sing-box
}

os_service_is_active() {
  run_root systemctl is-active --quiet sing-box
}

os_service_status() {
  run_root systemctl status sing-box --no-pager
}

os_service_logs() {
  run_root journalctl -u sing-box -f
}

os_service_remove() {
  run_root rm -f "$SERVICE_FILE"
  run_root rm -rf /etc/systemd/system/sing-box.service.d
}

# --- subscription auto-refresh (systemd timer) ------------------------------

os_subscription_timer_write() {
  local interval_sec="$1"
  local tmp_service tmp_timer

  tmp_service="$(mktemp)"
  cat > "$tmp_service" <<UNIT_EOF
[Unit]
Description=vpnc subscription refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpnc subscribe
UNIT_EOF
  run_root install -m 0644 "$tmp_service" "$SUBSCRIPTION_SERVICE_FILE"
  rm -f "$tmp_service"

  tmp_timer="$(mktemp)"
  cat > "$tmp_timer" <<UNIT_EOF
[Unit]
Description=Periodic vpnc subscription refresh

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval_sec}s
Persistent=true
Unit=${SUBSCRIPTION_SERVICE_UNIT}

[Install]
WantedBy=timers.target
UNIT_EOF
  run_root install -m 0644 "$tmp_timer" "$SUBSCRIPTION_TIMER_FILE"
  rm -f "$tmp_timer"

  run_root systemctl daemon-reload
}

os_subscription_timer_enable() {
  run_root systemctl enable --now "$SUBSCRIPTION_TIMER_UNIT"
}

os_subscription_timer_disable() {
  run_root systemctl disable --now "$SUBSCRIPTION_TIMER_UNIT" 2>/dev/null || true
}

os_subscription_timer_remove() {
  run_root rm -f "$SUBSCRIPTION_TIMER_FILE" "$SUBSCRIPTION_SERVICE_FILE"
  run_root systemctl daemon-reload
}

os_subscription_timer_status() {
  if run_root systemctl is-active --quiet "$SUBSCRIPTION_TIMER_UNIT" 2>/dev/null; then
    local next
    next="$(run_root systemctl show "$SUBSCRIPTION_TIMER_UNIT" -p NextElapseUSecRealtime --value 2>/dev/null)"
    echo "on, every ${SUBSCRIPTION_REFRESH_SEC}s (next: ${next:-unknown})"
  else
    echo "off"
  fi
}

delete_ip_rule_pref() {
  local pref="$1"
  while run_root ip rule del pref "$pref" 2>/dev/null; do :; done
}

clear_selected_routing() {
  run_root nft delete table inet vpnc 2>/dev/null || true
  delete_ip_rule_pref "$SELECTED_RULE_PREF"
  run_root ip route flush table "$SELECTED_ROUTE_TABLE" 2>/dev/null || true
}

clear_legacy_sing_box_routing() {
  run_root nft delete table inet sing-box 2>/dev/null || true
  delete_ip_rule_pref 9000
  delete_ip_rule_pref 9001
  delete_ip_rule_pref 9002
  delete_ip_rule_pref 9003
  run_root ip route flush table 2022 2>/dev/null || true
}

remove_custom_nft_files() {
  run_root rm -f "$NFT_FILE"
  run_root rmdir "$NFT_DIR" 2>/dev/null || true
}

write_custom_nft_file() {
  local include_uids_json="$1"
  local tmp_nft uid_set

  uid_set="$(jq -r 'map(tostring) | join(", ")' <<<"$include_uids_json")"
  [[ -n "$uid_set" ]] || die "No UIDs provided for selected-users mode"

  tmp_nft="$(mktemp)"
  cat > "$tmp_nft" <<NFT_EOF
table inet vpnc {
  chain output {
    type route hook output priority mangle; policy accept;
    meta mark $SELECTED_MARK_NFT return
    meta skuid { ${uid_set} } meta mark set $SELECTED_MARK_NFT
  }
}
NFT_EOF

  run_root install -d -m 0755 "$NFT_DIR"
  run_root install -m 0644 "$tmp_nft" "$NFT_FILE"
  rm -f "$tmp_nft"
}

apply_selected_routing_from_state() {
  ensure_runtime_dependencies
  ensure_cmd jq nft ip

  if ! run_root test -f "$STATE_FILE"; then
    clear_selected_routing
    return
  fi

  local user_scope include_uids_json
  user_scope="$(run_root jq -r '.user_scope // "all"' "$STATE_FILE")"

  if [[ "$user_scope" != "selected" ]]; then
    clear_selected_routing
    remove_custom_nft_files
    return
  fi

  include_uids_json="$(run_root jq -c '.include_uids // []' "$STATE_FILE")"
  if [[ "$include_uids_json" == "[]" ]]; then
    clear_selected_routing
    die "Selected-users mode requested, but include_uids is empty in $STATE_FILE"
  fi

  wait_for_interface "sbtun" 15 || die "sbtun interface did not appear in time"

  write_custom_nft_file "$include_uids_json"
  clear_selected_routing
  clear_legacy_sing_box_routing
  run_root ip route replace table "$SELECTED_ROUTE_TABLE" 198.18.0.0/30 dev sbtun src 198.18.0.1
  run_root ip route replace table "$SELECTED_ROUTE_TABLE" default via 198.18.0.2 dev sbtun
  run_root ip rule add fwmark "$SELECTED_MARK_HEX" lookup "$SELECTED_ROUTE_TABLE" pref "$SELECTED_RULE_PREF"
  run_root nft -f "$NFT_FILE"
}
