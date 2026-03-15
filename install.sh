#!/usr/bin/env bash
set -Eeuo pipefail

SKIP_BOOTSTRAP=0
if [[ $# -gt 0 ]] && [[ "$1" != "install" ]] && [[ "$1" != "--no-configure" ]]; then
  SKIP_BOOTSTRAP=1
fi

SCRIPT_NAME="vpnc"
MANAGER_PATH="/usr/local/bin/vpnc"
LEGACY_MANAGER_PATH="/usr/local/bin/makrelbka-vpnc"


SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[ERROR] sudo is required for installation" >&2
    exit 1
  fi
  SUDO="sudo"
fi

log() {
  echo "[INFO] $*"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

run_root() {
  if [[ -n "$SUDO" ]]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

ensure_sudo() {
  if [[ -n "$SUDO" ]]; then
    if ! "$SUDO" -n true 2>/dev/null; then
      log "Checking sudo privileges (you may be prompted for password)..."
      "$SUDO" true
    fi
  fi
}

install_dependencies() {
  local missing=()
  local cmd
  for cmd in curl jq tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return
  fi

  log "Installing dependencies: ${missing[*]}"

  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update -y
    run_root apt-get install -y curl jq tar ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y curl jq tar ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y curl jq tar ca-certificates
  elif command -v pacman >/dev/null 2>&1; then
    run_root pacman -Sy --noconfirm curl jq tar ca-certificates
  elif command -v zypper >/dev/null 2>&1; then
    run_root zypper --non-interactive install curl jq tar ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    run_root apk add --no-cache curl jq tar ca-certificates
  else
    die "Unsupported package manager. Install curl, jq, tar manually."
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    armv7l)
      echo "armv7"
      ;;
    armv6l)
      echo "armv6"
      ;;
    i386|i686)
      echo "386"
      ;;
    *)
      die "Unsupported architecture: $arch"
      ;;
  esac
}

install_sing_box() {
  local arch release_json tag version target_version asset_url tmp_dir bin_path

  arch="$(detect_arch)"
  log "Detected architecture: $arch"

  target_version="${SING_BOX_VERSION:-1.12.20}"

  if [[ "$target_version" == "latest" ]]; then
    release_json="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest)"
    tag="$(jq -r '.tag_name' <<<"$release_json")"
    version="${tag#v}"
  else
    tag="v${target_version}"
    version="${target_version}"
    release_json="$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/tags/${tag}")" \
      || die "Could not fetch sing-box release ${tag}. Set SING_BOX_VERSION=latest or a valid version."
  fi

  asset_url="$(jq -r --arg v "$version" --arg arch "$arch" '
    .assets[]
    | select(.name == ("sing-box-" + $v + "-linux-" + $arch + ".tar.gz"))
    | .browser_download_url
  ' <<<"$release_json" | head -n1)"

  if [[ -z "$asset_url" ]]; then
    asset_url="$(jq -r --arg arch "$arch" '
      .assets[]
      | select(.name | test("linux-" + $arch + "\\.tar\\.gz$"))
      | .browser_download_url
    ' <<<"$release_json" | head -n1)"
  fi

  [[ -n "$asset_url" ]] || die "Could not find release asset for architecture: $arch"

  tmp_dir="$(mktemp -d)"

  log "Downloading sing-box $tag"
  curl -fsSL "$asset_url" -o "$tmp_dir/sing-box.tar.gz"

  tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir"
  bin_path="$(find "$tmp_dir" -type f -name sing-box | head -n1)"
  [[ -n "$bin_path" ]] || die "sing-box binary was not found in archive"

  run_root install -m 0755 "$bin_path" /usr/local/bin/sing-box

  rm -rf "$tmp_dir"
  log "Installed sing-box to /usr/local/bin/sing-box"
}

install_manager() {
  local tmp_manager
  tmp_manager="$(mktemp)"

  cat > "$tmp_manager" <<'MANAGER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[ERROR] Run as root or install sudo" >&2
    exit 1
  fi
  SUDO="sudo"
fi

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

run_root() {
  if [[ -n "$SUDO" ]]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

ensure_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command is missing: $c"
  done
}

url_decode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

parse_query_map() {
  local query="$1"
  declare -gA URI_Q=()

  [[ -z "$query" ]] && return

  local pair k v
  IFS='&' read -r -a pairs <<<"$query"
  for pair in "${pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    k="${pair%%=*}"
    v=""
    if [[ "$pair" == *"="* ]]; then
      v="${pair#*=}"
    fi
    k="$(url_decode "$k")"
    v="$(url_decode "$v")"
    URI_Q["$k"]="$v"
  done
}

build_outbound_from_uri() {
  local uri="$1"
  local mode="$2"

  [[ "$uri" == vless://* ]] || die "Only vless:// URI is supported"

  local no_scheme="${uri#vless://}"
  [[ "$no_scheme" == *"@"* ]] || die "Invalid URI: missing @"

  local uuid="${no_scheme%%@*}"
  local rest="${no_scheme#*@}"
  local host_port query

  if [[ "$rest" == *"?"* ]]; then
    host_port="${rest%%\?*}"
    query="${rest#*\?}"
  else
    host_port="$rest"
    query=""
  fi

  host_port="${host_port%%/*}"
  query="${query%%#*}"

  local server port
  if [[ "$host_port" =~ ^\[([0-9a-fA-F:]+)\]:(.+)$ ]]; then
    server="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$host_port" == *":"* ]]; then
    server="${host_port%:*}"
    port="${host_port##*:}"
  else
    die "Invalid URI: missing host:port"
  fi

  [[ -n "$uuid" ]] || die "UUID is missing in URI"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port in URI: $port"

  parse_query_map "$query"

  local security="${URI_Q[security]:-}"
  local sni="${URI_Q[sni]:-${URI_Q[serverName]:-${URI_Q[servername]:-}}}"
  local flow="${URI_Q[flow]:-}"
  local fp="${URI_Q[fp]:-${URI_Q[fingerprint]:-chrome}}"
  local pbk="${URI_Q[pbk]:-${URI_Q[publicKey]:-}}"
  local sid="${URI_Q[sid]:-${URI_Q[shortid]:-${URI_Q[shortId]:-}}}"
  local alpn="${URI_Q[alpn]:-}"
  local network="${URI_Q[type]:-${URI_Q[network]:-tcp}}"
  local ws_path="${URI_Q[path]:-}"
  local ws_host="${URI_Q[host]:-}"
  local grpc_service="${URI_Q[serviceName]:-${URI_Q[service_name]:-}}"

  local outbound
  outbound="$(jq -n \
    --arg server "$server" \
    --argjson server_port "$port" \
    --arg uuid "$uuid" \
    --arg flow "$flow" \
    '{
      type: "vless",
      tag: "vless-out",
      server: $server,
      server_port: $server_port,
      uuid: $uuid
    }
    + (if $flow != "" then {flow: $flow} else {} end)
  ')"

  if [[ "$mode" == "reality" || "$security" == "reality" ]]; then
    [[ -n "$pbk" ]] || die "Reality public key (pbk/publicKey) is missing"

    outbound="$(jq \
      --arg sni "$sni" \
      --arg server "$server" \
      --arg pbk "$pbk" \
      --arg sid "$sid" \
      --arg fp "$fp" \
      --arg alpn "$alpn" '
      . + {
        tls: {
          enabled: true,
          server_name: (if $sni != "" then $sni else $server end),
          utls: {
            enabled: true,
            fingerprint: (if $fp != "" then $fp else "chrome" end)
          },
          reality: {
            enabled: true,
            public_key: $pbk,
            short_id: $sid
          }
        }
      }
      | if $alpn != "" then .tls.alpn = ($alpn | split(",")) else . end
    ' <<<"$outbound")"
  else
    if [[ "$security" == "tls" || -n "$sni" ]]; then
      outbound="$(jq \
        --arg sni "$sni" \
        --arg server "$server" \
        --arg alpn "$alpn" '
        . + {
          tls: {
            enabled: true,
            server_name: (if $sni != "" then $sni else $server end)
          }
        }
        | if $alpn != "" then .tls.alpn = ($alpn | split(",")) else . end
      ' <<<"$outbound")"
    fi
  fi

  if [[ "$network" == "ws" ]]; then
    outbound="$(jq \
      --arg ws_path "${ws_path:-/}" \
      --arg ws_host "$ws_host" '
      . + {
        transport: {
          type: "ws",
          path: $ws_path
        }
      }
      | if $ws_host != "" then .transport.headers = {Host: $ws_host} else . end
    ' <<<"$outbound")"
  elif [[ "$network" == "grpc" ]]; then
    outbound="$(jq \
      --arg service_name "$grpc_service" '
      . + {
        transport: {
          type: "grpc",
          service_name: $service_name
        }
      }
    ' <<<"$outbound")"
  fi

  echo "$outbound" | jq -c .
}

build_outbound_from_xray_json() {
  local json="$1"

  jq -c '
    . as $x
    | .settings.vnext[0] as $v
    | $v.users[0] as $u
    | {
        type: "vless",
        tag: "vless-out",
        server: $v.address,
        server_port: ($v.port | tonumber),
        uuid: $u.id
      }
    + (if ($u.flow // "") != "" then {flow: $u.flow} else {} end)
    + (
      if (($x.streamSettings.security // "") == "reality") then
        {
          tls: {
            enabled: true,
            server_name: ($x.streamSettings.realitySettings.serverName // $v.address),
            utls: {
              enabled: true,
              fingerprint: ($x.streamSettings.realitySettings.fingerprint // "chrome")
            },
            reality: {
              enabled: true,
              public_key: $x.streamSettings.realitySettings.publicKey,
              short_id: ($x.streamSettings.realitySettings.shortId // "")
            }
          }
        }
      elif (($x.streamSettings.security // "") == "tls") then
        {
          tls: {
            enabled: true,
            server_name: ($x.streamSettings.tlsSettings.serverName // $v.address)
          }
        }
      else
        {}
      end
    )
    + (
      if (($x.streamSettings.network // "tcp") == "ws") then
        (
          {
            transport: {
              type: "ws",
              path: ($x.streamSettings.wsSettings.path // "/")
            }
          }
          | if (($x.streamSettings.wsSettings.headers.Host // "") != "") then
              .transport.headers = {Host: $x.streamSettings.wsSettings.headers.Host}
            else
              .
            end
        )
      elif (($x.streamSettings.network // "tcp") == "grpc") then
        {
          transport: {
            type: "grpc",
            service_name: ($x.streamSettings.grpcSettings.serviceName // "")
          }
        }
      else
        {}
      end
    )
  ' <<<"$json"
}

build_outbound_from_json() {
  local json="$1"
  local mode="$2"
  local outbound=""

  echo "$json" | jq -e . >/dev/null 2>&1 || die "Invalid JSON"

  if echo "$json" | jq -e '.outbounds and (.outbounds | type == "array")' >/dev/null 2>&1; then
    outbound="$(echo "$json" | jq -c '(.outbounds | map(select((.type // .protocol) == "vless")) | .[0]) // empty')"
  fi

  if [[ -z "$outbound" || "$outbound" == "null" ]]; then
    if echo "$json" | jq -e '(.type // .protocol) == "vless"' >/dev/null 2>&1; then
      outbound="$(echo "$json" | jq -c '.')"
    fi
  fi

  if [[ -z "$outbound" || "$outbound" == "null" ]]; then
    if echo "$json" | jq -e '.protocol == "vless" and .settings.vnext[0] and .settings.vnext[0].users[0]' >/dev/null 2>&1; then
      outbound="$(build_outbound_from_xray_json "$json")"
    fi
  fi

  [[ -n "$outbound" && "$outbound" != "null" ]] || die "Could not extract VLESS outbound from JSON"

  outbound="$(echo "$outbound" | jq -c '
    .type = "vless"
    | .tag = "vless-out"
    | .server_port = (.server_port | tonumber)
  ')"

  echo "$outbound" | jq -e '.server and .server_port and .uuid' >/dev/null 2>&1 \
    || die "Outbound must include server, server_port and uuid"

  if [[ "$mode" == "reality" ]]; then
    echo "$outbound" | jq -e '.tls.reality.enabled == true and (.tls.reality.public_key | length > 0)' >/dev/null 2>&1 \
      || die "Selected VLESS+REALITY, but JSON does not contain tls.reality.public_key"
  fi

  echo "$outbound"
}

select_mode() {
  local choice
  while true; do
    echo >&2
    echo "Select VPN type:" >&2
    echo "  1) VLESS + REALITY" >&2
    echo "  2) VLESS" >&2
    read -r -p "Enter number [1-2] (default: 1): " choice
    choice="${choice:-1}"

    case "$choice" in
      1)
        echo "reality"
        return
        ;;
      2)
        echo "vless"
        return
        ;;
      *)
        echo "Invalid choice" >&2
        ;;
    esac
  done
}

select_user_scope() {
  echo >&2
  echo "Apply VPN for: all users" >&2
  echo "Selected-users mode is temporarily disabled." >&2
  echo "all"
}


read_selected_user_uids() {
  local input user uid
  local -a users=()
  local -a uids=()

  echo
  read -r -p "Enter usernames separated by spaces: " input

  [[ -n "${input//[[:space:]]/}" ]] || die "No usernames provided"

  read -r -a users <<<"$input"

  for user in "${users[@]}"; do
    if ! id "$user" >/dev/null 2>&1; then
      die "User does not exist: $user"
    fi

    uid="$(id -u "$user")"
    uids+=("$uid")
  done

  printf '%s\n' "${uids[@]}" | jq -R 'tonumber' | jq -s .
}

select_input_type() {
  local choice
  while true; do
    echo >&2
    echo "Config input format:" >&2
    echo "  1) VLESS URL (vless://...)" >&2
    echo "  2) JSON config" >&2
    read -r -p "Enter number [1-2] (default: 1): " choice
    choice="${choice:-1}"

    case "$choice" in
      1)
        echo "url"
        return
        ;;
      2)
        echo "json"
        return
        ;;
      *)
        echo "Invalid choice" >&2
        ;;
    esac
  done
}

read_json_payload() {
  local payload
  echo >&2
  echo "Paste JSON below, then press Ctrl-D:" >&2
  payload="$(cat)"

  if [[ -z "${payload//[[:space:]]/}" ]]; then
    read -r -p "No JSON pasted. Enter path to JSON file: " json_path
    [[ -f "$json_path" ]] || die "File does not exist: $json_path"
    payload="$(cat "$json_path")"
  fi

  echo "$payload"
}

write_service_file() {
  if [[ -n "$SUDO" ]]; then
    $SUDO tee "$SERVICE_FILE" >/dev/null <<'UNIT_EOF'
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_EOF
  else
    cat > "$SERVICE_FILE" <<'UNIT_EOF'
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_EOF
  fi
}
write_config() {
  local outbound="$1"
  local include_uids_json="${2:-[]}"
  local tmp_config backup_file

  tmp_config="$(mktemp)"

  jq -n \
    --argjson outbound "$outbound" \
    --argjson include_uids "$include_uids_json" '
    {
      log: { level: "info" },
      dns: {
        servers: [
          {
            type: "tls",
            tag: "cloudflare",
            server: "1.1.1.1"
          },
          {
            type: "tls",
            tag: "google",
            server: "8.8.8.8"
          }
        ],
        final: "cloudflare"
      },
      inbounds: [
        (
          {
            type: "tun",
            tag: "tun-in",
            interface_name: "sbtun",
            address: ["198.18.0.1/30"],
            auto_route: true,
            auto_redirect: true,
            strict_route: true,
            mtu: 1500,
            stack: "system"
          }
          +
          (if ($include_uids | length) > 0 then
             { include_uid: $include_uids }
           else
             {}
           end)
        )
      ],
      outbounds: [
        $outbound,
        { type: "direct", tag: "direct" }
      ],
      route: {
        auto_detect_interface: true,
        rules: [
          { action: "sniff" },
          { protocol: "dns", action: "hijack-dns" }
        ],
        final: "vless-out"
      }
    }
  ' > "$tmp_config"

  run_root install -d -m 0755 "$CONFIG_DIR"

  if run_root test -f "$CONFIG_FILE"; then
    backup_file="/etc/sing-box/config.backup-$(date +%Y%m%d-%H%M%S).json"
    run_root cp "$CONFIG_FILE" "$backup_file"
    log "Previous config backup: $backup_file"
  fi

  run_root install -m 0600 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"
}
configure_vpn() {
  ensure_cmd jq systemctl sing-box id

  local mode input_type user_scope outbound uri json_payload include_uids_json

  mode="$(select_mode)"
  input_type="$(select_input_type)"
  user_scope="$(select_user_scope)"
  include_uids_json='[]'

  if [[ "$input_type" == "url" ]]; then
    echo
    read -r -p "Paste VLESS URL: " uri
    outbound="$(build_outbound_from_uri "$uri" "$mode")"
  else
    json_payload="$(read_json_payload)"
    outbound="$(build_outbound_from_json "$json_payload" "$mode")"
  fi

  if [[ "$user_scope" == "selected" ]]; then
    include_uids_json="$(read_selected_user_uids)"
  fi
  
  write_config "$outbound" "$include_uids_json"
  write_service_file

  run_root systemctl daemon-reload
  run_root systemctl enable sing-box >/dev/null

  run_root /usr/local/bin/sing-box check -c "$CONFIG_FILE"
  run_root systemctl restart sing-box
  sleep 2

  if run_root systemctl is-active --quiet sing-box; then
    local current_ip
    current_ip=""

    if command -v curl >/dev/null 2>&1; then
      current_ip="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
      [[ -n "$current_ip" ]] || current_ip="$(curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null || true)"
      [[ -n "$current_ip" ]] || current_ip="$(curl -fsSL --max-time 8 https://2ip.ru 2>/dev/null || true)"
    fi

    if [[ -n "$current_ip" ]]; then
      log "VPN config applied. All good."
      echo "[INFO] Your current public IP: $current_ip"
    else
      log "VPN config applied. All good."
      echo "[INFO] Could not detect public IP automatically."
    fi
  else
    die "sing-box failed to start. Run: $(basename "$0") logs"

  fi
}

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat <<HELP_EOF
Usage: ${cmd} <command>


Commands:
  configure     Interactive setup (choose VLESS/VLESS+REALITY and provide URL/JSON)
  reconfigure   Same as configure
  status        Show service status
  start         Start VPN service
  stop          Stop VPN service
  restart       Restart VPN service
  enable        Enable autostart on boot
  disable       Disable autostart on boot
  uninstall     Completely remove sing-box and all configurations
  logs          Follow sing-box logs
  show-config   Print /etc/sing-box/config.json
  help          Show this help
HELP_EOF
}

uninstall_vpn() {
  echo "[WARN] This will completely remove sing-box and all its configurations!"
  echo "[WARN] The following will be deleted:"
  echo "  - /usr/local/bin/sing-box"
  echo "  - /etc/sing-box/"
  echo "  - /etc/systemd/system/sing-box.service"
  echo "  - /usr/local/bin/vpnc"
  echo "  - /usr/local/bin/makrelbka-vpnc"
  echo
  read -r -p "Are you absolutely sure? Type 'yes' to continue: " confirmation
  
  if [[ "$confirmation" != "yes" ]]; then
    echo "Uninstall cancelled."
    return
  fi

  echo "Stopping and disabling sing-box service..."
  run_root systemctl stop sing-box 2>/dev/null || true
  run_root systemctl disable sing-box 2>/dev/null || true
  
  echo "Removing systemd service file..."
  run_root rm -f /etc/systemd/system/sing-box.service
  run_root systemctl daemon-reload
  
  echo "Removing sing-box binary..."
  run_root rm -f /usr/local/bin/sing-box
  
  echo "Removing configuration directory..."
  run_root rm -rf /etc/sing-box
  
  echo "Removing manager script..."
  run_root rm -f /usr/local/bin/vpnc /usr/local/bin/makrelbka-vpnc
  
  echo "[SUCCESS] sing-box has been completely uninstalled."
  echo "You may want to reboot your system to clean up any remaining TUN interfaces."
}

main() {
  local cmd="${1:-help}"

  case "$cmd" in
    configure|reconfigure)
      configure_vpn
      ;;
    status)
      run_root systemctl status sing-box --no-pager
      ;;
    start)
      run_root systemctl start sing-box
      ;;
    stop)
      run_root systemctl stop sing-box
      ;;
    restart)
      run_root systemctl restart sing-box
      ;;
    enable)
      run_root systemctl enable sing-box
      ;;
    disable)
      run_root systemctl disable sing-box
      ;;
    uninstall)
      uninstall_vpn
      ;;
    logs)
      run_root journalctl -u sing-box -f
      ;;
    show-config)
      run_root cat "$CONFIG_FILE"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
MANAGER_EOF

  run_root install -m 0755 "$tmp_manager" "$MANAGER_PATH"
  run_root ln -sf "$MANAGER_PATH" "$LEGACY_MANAGER_PATH"
  rm -f "$tmp_manager"

  log "Installed manager commands: $MANAGER_PATH and $LEGACY_MANAGER_PATH"

}

# Это функция установки (bootstrap)
bootstrap() {
  local no_configure="0"
  if [[ "${1:-}" == "--no-configure" ]]; then
    no_configure="1"
  fi

  ensure_sudo
  install_dependencies
  install_sing_box
  install_manager

  log "Bootstrap completed"
  echo
  echo "Use these commands:"
  echo "  vpnc configure"
  echo "  vpnc status"
  echo "  vpnc start|stop|restart"
  echo
  echo "Compatibility alias:"
  echo "  makrelbka-vpnc configure"
  echo "  makrelbka-vpnc status"
  echo "  makrelbka-vpnc start|stop|restart"

  echo

  if [[ "$no_configure" == "0" ]]; then
    "$MANAGER_PATH" configure
  else
    log "Skipping interactive configure (--no-configure)"
  fi
}

# Основная логика
if [[ $SKIP_BOOTSTRAP -eq 1 ]]; then
  if [[ -f "$MANAGER_PATH" ]]; then
    "$MANAGER_PATH" "$@"
  elif [[ -f "$LEGACY_MANAGER_PATH" ]]; then
    "$LEGACY_MANAGER_PATH" "$@"
  else
    echo "[ERROR] Manager not found at $MANAGER_PATH or $LEGACY_MANAGER_PATH"
    exit 1
  fi
else
  bootstrap "$@"
fi

