# shellcheck shell=bash
# Shared logic for vpnc: sing-box config generation, URI/subscription parsing,
# rules, prompts. OS-specific pieces (service, deps, routing) live in lib/<os>.sh
# and are called through the os_* / *_selected_routing functions defined there.
# Compatible with bash 3.2 (macOS system bash) — no associative arrays.

export PATH="/usr/local/sbin:/usr/local/bin:/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
STATE_FILE="/etc/sing-box/vpnc-state.json"
NFT_DIR="/etc/sing-box/nftables.d"
NFT_FILE="${NFT_DIR}/vpnc-selected-users.nft"
SELECTED_MARK_HEX="0x2023"
SELECTED_MARK_NFT="0x00002023"
SELECTED_ROUTE_TABLE="10023"
SELECTED_RULE_PREF="8990"

RULES_FILE="${CONFIG_DIR}/vpnc-rules.json"
SUBSCRIPTION_STATE_FILE="${CONFIG_DIR}/vpnc-subscription.json"
CLASH_UI_DIR="${CONFIG_DIR}/ui"
# Default IP:port suggested for the dashboard/API prompt. Comes from the OS layer
# (OS_DEFAULT_CLASH_BIND: the Wi-Fi hotspot address on Linux, loopback on macOS).
# Overridable via VPNC_CLASH_API_BIND; always confirmable/editable interactively
# when the dashboard is enabled during configure/subscribe.
CLASH_API_BIND="${VPNC_CLASH_API_BIND:-${OS_DEFAULT_CLASH_BIND:-127.0.0.1:9090}}"
# Local path or URL to a rules JSON ({"rules": [...]}) to seed $RULES_FILE from on first
# use. Neither is required — with no seed, rules start out empty and can be built up
# with `rules edit`/`rules toggle`.
RULES_SEED_PATH="${VPNC_RULES_SEED_PATH:-}"
RULES_SEED_URL="${VPNC_RULES_SEED_URL:-}"
# How often a saved subscription is re-fetched in the background (systemd timer on
# Linux, launchd StartInterval on macOS), in seconds. Set up by configure_subscription
# once a subscription is active; torn down when switching back to single-server mode.
SUBSCRIPTION_REFRESH_SEC="${VPNC_SUBSCRIPTION_REFRESH_SEC:-300}"

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[ERROR] Run as root or install sudo" >&2
    exit 1
  fi
  SUDO="sudo"
fi

log() {
  echo "[INFO] $*" >&2
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

detect_os() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "macos" ;;
    *) die "Unsupported OS: $(uname -s) (supported: Linux, macOS)" ;;
  esac
}

# Kept as a thin alias so call sites stay OS-agnostic; the real work is os_ensure_deps.
ensure_runtime_dependencies() {
  os_ensure_deps
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

# uri_q <default> <key>...: value of the first non-empty query key from $URI_QUERY
# (already stripped of '?' and '#fragment'), URL-decoded, else <default>.
uri_q() {
  local def="$1" key pair v
  local -a pairs=()
  shift

  if [[ -n "${URI_QUERY:-}" ]]; then
    IFS='&' read -r -a pairs <<<"$URI_QUERY"
    for key in "$@"; do
      for pair in ${pairs[@]+"${pairs[@]}"}; do
        if [[ "${pair%%=*}" == "$key" && "$pair" == *"="* ]]; then
          v="$(url_decode "${pair#*=}")"
          if [[ -n "$v" ]]; then
            printf '%s' "$v"
            return
          fi
        fi
      done
    done
  fi

  printf '%s' "$def"
}

decode_base64_urlsafe() {
  local data="$1"
  local rem

  data="${data//-/+}"
  data="${data//_/\/}"
  rem=$(( ${#data} % 4 ))
  if [[ $rem -eq 2 ]]; then
    data="${data}=="
  elif [[ $rem -eq 3 ]]; then
    data="${data}="
  elif [[ $rem -eq 1 ]]; then
    die "Invalid base64 payload"
  fi

  printf '%s' "$data" | base64 -d 2>/dev/null || die "Failed to decode base64 payload"
}

build_vless_outbound_from_uri() {
  local uri="$1"
  local mode="${2:-}"

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

  URI_QUERY="$query"

  local security sni flow fp pbk sid alpn network ws_path ws_host grpc_service
  security="$(uri_q "" security)"
  sni="$(uri_q "" sni serverName servername)"
  flow="$(uri_q "" flow)"
  fp="$(uri_q chrome fp fingerprint)"
  pbk="$(uri_q "" pbk publicKey)"
  sid="$(uri_q "" sid shortid shortId)"
  alpn="$(uri_q "" alpn)"
  network="$(uri_q tcp type network)"
  ws_path="$(uri_q "" path)"
  ws_host="$(uri_q "" host)"
  grpc_service="$(uri_q "" serviceName service_name)"

  local outbound
  outbound="$(jq -n \
    --arg server "$server" \
    --argjson server_port "$port" \
    --arg uuid "$uuid" \
    --arg flow "$flow" \
    '{
      type: "vless",
      tag: "proxy-out",
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

build_shadowsocks_outbound_from_uri() {
  local uri="$1"
  local no_scheme="${uri#ss://}"
  local fragment=""
  local query=""
  local host_port=""
  local userinfo=""
  local decoded=""
  local method=""
  local password=""
  local server=""
  local port=""

  if [[ "$no_scheme" == *"#"* ]]; then
    fragment="${no_scheme#*#}"
    no_scheme="${no_scheme%%#*}"
  fi

  if [[ "$no_scheme" == *"?"* ]]; then
    query="${no_scheme#*\?}"
    no_scheme="${no_scheme%%\?*}"
  fi

  if [[ "$no_scheme" == *"@"* ]]; then
    userinfo="${no_scheme%%@*}"
    host_port="${no_scheme#*@}"
    if [[ "$userinfo" != *:* ]]; then
      userinfo="$(decode_base64_urlsafe "$userinfo")"
    fi
  else
    decoded="$(decode_base64_urlsafe "$no_scheme")"
    [[ "$decoded" == *"@"* ]] || die "Invalid ss:// URI"
    userinfo="${decoded%%@*}"
    host_port="${decoded#*@}"
  fi

  [[ "$userinfo" == *:* ]] || die "Invalid ss:// credentials"
  method="${userinfo%%:*}"
  password="${userinfo#*:}"

  if [[ "$host_port" =~ ^\[([0-9a-fA-F:]+)\]:(.+)$ ]]; then
    server="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$host_port" == *":"* ]]; then
    server="${host_port%:*}"
    port="${host_port##*:}"
  else
    die "Invalid ss:// URI: missing host:port"
  fi

  [[ -n "$method" ]] || die "Shadowsocks method is missing"
  [[ -n "$password" ]] || die "Shadowsocks password is missing"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port in ss:// URI: $port"

  jq -cn \
    --arg server "$server" \
    --argjson server_port "$port" \
    --arg method "$method" \
    --arg password "$password" '
    {
      type: "shadowsocks",
      tag: "proxy-out",
      server: $server,
      server_port: $server_port,
      method: $method,
      password: $password
    }
  '
}

build_outbound_from_uri() {
  local uri="$1"
  local mode="${2:-}"

  case "$uri" in
    vless://*)
      build_vless_outbound_from_uri "$uri" "$mode"
      ;;
    ss://*)
      build_shadowsocks_outbound_from_uri "$uri"
      ;;
    *)
      die "Only vless:// and ss:// URIs are supported"
      ;;
  esac
}

build_outbound_from_xray_json() {
  local json="$1"

  jq -c '
    . as $x
    | .settings.vnext[0] as $v
    | $v.users[0] as $u
    | {
        type: "vless",
        tag: "proxy-out",
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
    | .tag = "proxy-out"
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

detect_uri_scheme() {
  local uri="$1"
  case "$uri" in
    vless://*) echo "vless" ;;
    ss://*) echo "ss" ;;
    *) echo "unknown" ;;
  esac
}

select_user_scope() {
  local choice

  if ! os_selected_users_supported; then
    echo "all"
    return
  fi

  while true; do
    echo >&2
    echo "Apply VPN for:" >&2
    echo "  1) All users" >&2
    echo "  2) Only selected users" >&2
    echo "     note: implemented via custom nftables UID rules (Linux only)" >&2
    read -r -p "Enter number [1-2] (default: 1): " choice
    choice="${choice:-1}"

    case "$choice" in
      1)
        echo "all"
        return
        ;;
      2)
        echo "selected"
        return
        ;;
      *)
        echo "Invalid choice" >&2
        ;;
    esac
  done
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

read_json_payload() {
  local payload json_path
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

select_input_type() {
  local choice
  while true; do
    echo >&2
    echo "Config input format:" >&2
    echo "  1) VPN URL (vless://... or ss://...)" >&2
    echo "  2) JSON config" >&2
    echo "  3) Subscription URL (multiple servers)" >&2
    read -r -p "Enter number [1-3] (default: 1): " choice
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
      3)
        echo "subscription"
        return
        ;;
      *)
        echo "Invalid choice" >&2
        ;;
    esac
  done
}

read_subscription_url() {
  local url
  echo >&2
  read -r -p "Paste subscription URL: " url
  [[ -n "$url" ]] || die "Subscription URL is required"
  echo "$url"
}

select_dashboard_enabled() {
  local choice
  echo >&2
  read -r -p "Enable web dashboard (Clash-compatible UI)? [y/N]: " choice
  case "$choice" in
    y|Y|yes|Yes|YES)
      echo "true"
      ;;
    *)
      echo "false"
      ;;
  esac
}

select_clash_api_bind() {
  local input
  echo >&2
  read -r -p "Dashboard bind address [IP:port] (default: ${CLASH_API_BIND}): " input
  if [[ -n "$input" ]]; then
    echo "$input"
  else
    echo "$CLASH_API_BIND"
  fi
}

# A well-known path the invoking (non-root) user can drop a rules JSON into without
# needing sudo, so "I already put a file there" in select_rules_source has somewhere
# fixed to point at. Resolves the real user's home even when running under sudo.
default_rules_candidate_path() {
  local home
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    home="$(eval echo "~${SUDO_USER}" 2>/dev/null)"
  fi
  [[ -n "$home" ]] || home="${HOME:-/root}"
  echo "${home}/vpnc-rules.json"
}

# Interactive rules-source prompt, run once during configure/reconfigure (never during
# the unattended `subscribe` background refresh). Delegates to cmd_rules_import, which
# validates the JSON and keeps a timestamped backup of whatever was there before.
select_rules_source() {
  local default_path choice current_count
  default_path="$(default_rules_candidate_path)"

  echo >&2
  echo "Direct-vs-VPN rules (which domains/apps/ports bypass the VPN):" >&2
  if run_root test -f "$RULES_FILE"; then
    current_count="$(run_root jq '.rules | length' "$RULES_FILE" 2>/dev/null || echo '?')"
    echo "  Current: $current_count rule group(s) already set (${RULES_FILE})." >&2
  fi
  echo "  1) Skip for now (keep as-is)" >&2
  echo "  2) I put a file at ${default_path} — use it" >&2
  echo "  3) Download from a URL" >&2
  echo "  4) Use a local file path" >&2
  read -r -p "Enter number [1-4] (default: 1): " choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      return
      ;;
    2)
      [[ -f "$default_path" ]] || die "No file found at $default_path"
      cmd_rules_import "$default_path"
      ;;
    3)
      local url
      read -r -p "Rules URL: " url
      [[ -n "$url" ]] || die "URL is required"
      cmd_rules_import "$url"
      ;;
    4)
      local path
      read -r -p "Rules file path: " path
      [[ -n "$path" ]] || die "Path is required"
      cmd_rules_import "$path"
      ;;
    *)
      warn "Invalid choice, skipping rules import"
      ;;
  esac
}

write_state_file() {
  local user_scope="$1"
  local include_uids_json="${2:-[]}"
  local dashboard_enabled="${3:-false}"
  local clash_api_bind="${4:-$CLASH_API_BIND}"
  local tmp_state

  tmp_state="$(mktemp)"

  jq -n \
    --arg user_scope "$user_scope" \
    --argjson include_uids "$include_uids_json" \
    --argjson dashboard_enabled "$dashboard_enabled" \
    --arg clash_api_bind "$clash_api_bind" '
    {
      user_scope: $user_scope,
      include_uids: $include_uids,
      dashboard_enabled: $dashboard_enabled,
      clash_api_bind: $clash_api_bind
    }
  ' > "$tmp_state"

  run_root install -d -m 0755 "$CONFIG_DIR"
  run_root install -m 0600 "$tmp_state" "$STATE_FILE"
  rm -f "$tmp_state"
}

write_config() {
  local outbound="$1"
  local user_scope="$2"
  local dashboard_enabled="${3:-false}"
  local auto_route_json auto_redirect_json tmp_config backup_file outbound_tag custom_dns_rules_json

  auto_route_json=false
  auto_redirect_json=false
  if [[ "$user_scope" == "all" ]]; then
    auto_route_json=true
    auto_redirect_json="${OS_AUTO_REDIRECT:-false}"
  fi

  tmp_config="$(mktemp)"
  outbound_tag="$(jq -r '.tag' <<<"$outbound")"
  custom_dns_rules_json="$(compile_custom_dns_rules)"

  jq -n \
    --argjson outbound "$outbound" \
    --arg outbound_tag "$outbound_tag" \
    --argjson auto_route "$auto_route_json" \
    --argjson auto_redirect "$auto_redirect_json" \
    --arg tun_name "${OS_TUN_INTERFACE:-}" \
    --argjson custom_dns_rules "$custom_dns_rules_json" \
    --argjson dashboard_enabled "$dashboard_enabled" \
    --arg clash_bind "$CLASH_API_BIND" \
    --arg clash_ui_dir "$CLASH_UI_DIR" '
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
          },
          {
            type: "local",
            tag: "local"
          }
        ],
        rules: $custom_dns_rules,
        final: "cloudflare"
      },
      inbounds: [
        (
          {
            type: "tun",
            tag: "tun-in",
            address: ["198.18.0.1/30"],
            auto_route: $auto_route,
            auto_redirect: $auto_redirect,
            strict_route: true,
            mtu: 1500,
            stack: "system"
          }
          + (if $tun_name != "" then {interface_name: $tun_name} else {} end)
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
        final: $outbound_tag
      }
    }
    + (
      if $dashboard_enabled then
        {
          experimental: {
            clash_api: {
              external_controller: $clash_bind,
              external_ui: $clash_ui_dir,
              external_ui_download_url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip",
              external_ui_download_detour: "direct",
              secret: "",
              default_mode: "rule"
            }
          }
        }
      else
        {}
      end
    )
  ' > "$tmp_config"

  run_root install -d -m 0755 "$CONFIG_DIR"

  if [[ "$dashboard_enabled" == "true" ]]; then
    run_root install -d -m 0755 "$CLASH_UI_DIR"
  fi

  if run_root test -f "$CONFIG_FILE"; then
    backup_file="${CONFIG_DIR}/config.backup-$(date +%Y%m%d-%H%M%S).json"
    run_root cp "$CONFIG_FILE" "$backup_file"
    log "Previous config backup: $backup_file"
  fi

  run_root install -m 0600 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"
}

configure_vpn() {
  ensure_runtime_dependencies
  ensure_cmd jq sing-box id
  os_check_cmds

  local mode input_type user_scope outbound uri json_payload include_uids_json uri_scheme dashboard_enabled sub_url

  # Asked once here (never during the unattended `subscribe` background refresh) so it
  # covers both the single-server and subscription paths below.
  select_rules_source

  input_type="$(select_input_type)"

  if [[ "$input_type" == "subscription" ]]; then
    ensure_cmd curl base64
    sub_url="$(read_subscription_url)"
    dashboard_enabled="$(select_dashboard_enabled)"
    [[ "$dashboard_enabled" == "true" ]] && CLASH_API_BIND="$(select_clash_api_bind)"
    configure_subscription "$sub_url" "$dashboard_enabled"
    return
  fi

  user_scope="$(select_user_scope)"
  include_uids_json='[]'
  mode=""

  if [[ "$input_type" == "url" ]]; then
    echo
    read -r -p "Paste VPN URL: " uri
    uri_scheme="$(detect_uri_scheme "$uri")"
    [[ "$uri_scheme" != "unknown" ]] || die "Unsupported URI scheme. Expected vless:// or ss://"
    outbound="$(build_outbound_from_uri "$uri")"
  else
    mode="$(select_mode)"
    json_payload="$(read_json_payload)"
    outbound="$(build_outbound_from_json "$json_payload" "$mode")"
  fi

  if [[ "$user_scope" == "selected" ]]; then
    include_uids_json="$(read_selected_user_uids)"
  fi

  dashboard_enabled="$(select_dashboard_enabled)"
  [[ "$dashboard_enabled" == "true" ]] && CLASH_API_BIND="$(select_clash_api_bind)"

  write_config "$outbound" "$user_scope" "$dashboard_enabled"
  write_state_file "$user_scope" "$include_uids_json" "$dashboard_enabled" "$CLASH_API_BIND"
  os_service_write

  # Single-server mode has no subscription to refresh — drop any leftover
  # subscription state and background refresh timer from a previous `subscribe`.
  run_root rm -f "$SUBSCRIPTION_STATE_FILE"
  os_subscription_timer_disable
  os_subscription_timer_remove

  if [[ "$user_scope" == "selected" ]]; then
    clear_selected_routing
    clear_legacy_sing_box_routing
  else
    clear_selected_routing
  fi

  os_service_reload
  os_service_enable >/dev/null

  run_root /usr/local/bin/sing-box check -c "$CONFIG_FILE"
  os_service_restart
  sleep 2

  if os_service_is_active; then
    local current_ip
    current_ip=""

    if command -v curl >/dev/null 2>&1; then
      current_ip="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
      [[ -n "$current_ip" ]] || current_ip="$(curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null || true)"
      [[ -n "$current_ip" ]] || current_ip="$(curl -fsSL --max-time 8 https://2ip.ru 2>/dev/null || true)"
    fi

    if [[ "$user_scope" == "selected" ]]; then
      log "VPN config applied. Selected-users mode uses Linux nftables + ip rule by UID."
    else
      log "VPN config applied. All users mode is active."
    fi

    if [[ -n "$current_ip" ]]; then
      echo "[INFO] Your current public IP: $current_ip"
    else
      echo "[INFO] Could not detect public IP automatically."
    fi
  else
    die "sing-box failed to start. Run: $(basename "$0") logs"
  fi
}

# ---------------------------------------------------------------------------
# Subscription mode: fetch a subscription URL, turn every entry into a
# sing-box outbound (reusing build_outbound_from_uri), group them into a
# selector ("proxy") + urltest ("auto") pair, and optionally (only if the
# caller opted in) enable the built-in clash_api + external_ui dashboard
# (metacubexd) so servers/ping/speed/pick can be managed from a browser
# instead of the CLI.
# ---------------------------------------------------------------------------

decode_subscription_text() {
  local raw="$1" decoded

  if grep -qE '^(vless|ss|vmess|trojan)://' <<<"$raw"; then
    printf '%s' "$raw"
    return
  fi

  decoded="$(tr -d '[:space:]' <<<"$raw" | base64 -d 2>/dev/null || true)"
  if [[ -n "$decoded" ]] && grep -qE '^(vless|ss|vmess|trojan)://' <<<"$decoded"; then
    printf '%s' "$decoded"
    return
  fi

  die "Subscription format is not recognized (expected plain vless/ss URIs or a base64 blob of them)"
}

fetch_subscription_url() {
  local url="$1" raw
  raw="$(curl -fsSL --max-time 20 "$url")" || die "Could not download subscription: $url"
  decode_subscription_text "$raw"
}

# Populates globals SUBSCRIPTION_TAGS_JSON / SUBSCRIPTION_PROXIES_JSON.
build_outbounds_from_subscription() {
  local text="$1"
  local -a tags=()
  local -a items=()
  local seen_names=$'\n'
  local line frag name base n outbound scheme

  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue

    scheme="$(detect_uri_scheme "$line")"
    if [[ "$scheme" == "unknown" ]]; then
      warn "Skipped subscription line (unknown scheme)"
      continue
    fi

    if [[ "$line" == *"#"* ]]; then
      name="$(url_decode "${line#*#}")"
    else
      name="node-$(( ${#items[@]} + 1 ))"
    fi
    [[ -n "$name" ]] || name="node-$(( ${#items[@]} + 1 ))"

    base="$name"
    n=2
    while [[ "$seen_names" == *$'\n'"$name"$'\n'* ]]; do
      name="${base} #${n}"
      n=$((n + 1))
    done
    seen_names="${seen_names}${name}"$'\n'

    if ! outbound="$(build_outbound_from_uri "$line" "" 2>/dev/null)"; then
      warn "Skipped node (could not parse): $name"
      continue
    fi

    outbound="$(jq -c --arg tag "$name" '.tag = $tag' <<<"$outbound")"
    tags+=("$name")
    items+=("$outbound")
  done <<<"$text"

  [[ ${#items[@]} -gt 0 ]] || die "Could not parse any server from the subscription"

  SUBSCRIPTION_TAGS_JSON="$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)"
  SUBSCRIPTION_PROXIES_JSON="$(printf '%s\n' "${items[@]}" | jq -s .)"
}

seed_rules_file_if_missing() {
  run_root test -f "$RULES_FILE" && return

  run_root install -d -m 0755 "$CONFIG_DIR"
  local tmp source_desc
  tmp="$(mktemp)"

  if [[ -n "$RULES_SEED_PATH" ]]; then
    [[ -f "$RULES_SEED_PATH" ]] || die "VPNC_RULES_SEED_PATH is set but file does not exist: $RULES_SEED_PATH"
    cp "$RULES_SEED_PATH" "$tmp"
    source_desc="$RULES_SEED_PATH"
  elif [[ -n "$RULES_SEED_URL" ]]; then
    curl -fsSL --max-time 20 "$RULES_SEED_URL" -o "$tmp" || die "Could not download rules seed: $RULES_SEED_URL"
    source_desc="$RULES_SEED_URL"
  else
    printf '%s\n' '{"rules": []}' > "$tmp"
    source_desc=""
  fi

  jq -e '.rules and (.rules | type == "array")' "$tmp" >/dev/null 2>&1 \
    || die "Rules seed is not valid JSON of the form {\"rules\": [...]}: ${source_desc:-(built-in empty default)}"

  run_root install -m 0644 "$tmp" "$RULES_FILE"
  rm -f "$tmp"

  if [[ -n "$source_desc" ]]; then
    log "Created rules file from seed ($source_desc): $RULES_FILE"
    warn "process_name/port rules only match traffic that originates on this box itself (sing-box runs on the router, not on client devices) — domain/ip_cidr rules still work normally for hotspot clients."
  else
    log "Created empty rules file: $RULES_FILE (add groups with: $(basename "$0") rules edit, or set VPNC_RULES_SEED_PATH/VPNC_RULES_SEED_URL before first use)"
  fi
}

compile_custom_rules() {
  seed_rules_file_if_missing

  run_root jq -c '
    def cond_keys: ["domain","domain_suffix","domain_keyword","domain_regex","ip_cidr","port","port_range","process_name","package_name","network","protocol"];
    [
      .rules[]
      | select(.switch == true)
      | . as $r
      | (cond_keys | map(select($r[.] != null and ($r[.] | length) > 0))) as $keys
      | select(($keys | length) > 0)
      | if ($keys | length) == 1 then
          { ($keys[0]): $r[$keys[0]], outbound: $r.outbound }
        else
          {
            type: "logical",
            mode: (if $r.or == false then "and" else "or" end),
            rules: [ $keys[] as $k | { ($k): $r[$k] } ],
            outbound: $r.outbound
          }
        end
    ]
  ' "$RULES_FILE"
}

# Derives dns.rules from the same rules file as compile_custom_rules: any *domain-only*
# group routed "direct" also gets its DNS queries answered by the "local" (OS/system
# resolver) DNS server instead of the hijacked cloudflare/google one. Needed for
# corp/internal hostnames (e.g. behind Cisco AnyConnect's split-DNS) that plain public
# DNS can't resolve — matching them for direct routing alone isn't enough if the queried
# name never resolves in the first place. ip_cidr/port/process_name/network conditions
# don't carry meaning for DNS lookups, so groups using only those are left out (DNS
# still resolves via cloudflare/google for them, which is what you want for pure IP or
# process-based rules).
compile_custom_dns_rules() {
  local compiled
  compiled="$(compile_custom_rules)"

  jq -c '
    def domain_keys: ["domain","domain_suffix","domain_keyword","domain_regex"];
    [
      .[]
      | select(.outbound == "direct")
      | select(
          if .type == "logical" then
            (.rules | all(keys[0] as $k | (domain_keys | index($k)) != null))
          else
            (((keys - ["outbound"])[0]) as $k | (domain_keys | index($k)) != null)
          end
        )
      | (del(.outbound) + {server: "local"})
    ]
  ' <<<"$compiled"
}

write_subscription_config() {
  local dashboard_enabled="${1:-false}"
  local tmp_config backup_file custom_rules_json custom_dns_rules_json

  custom_rules_json="$(compile_custom_rules)"
  custom_dns_rules_json="$(compile_custom_dns_rules)"
  tmp_config="$(mktemp)"

  jq -n \
    --argjson proxies "$SUBSCRIPTION_PROXIES_JSON" \
    --argjson tags "$SUBSCRIPTION_TAGS_JSON" \
    --argjson custom_rules "$custom_rules_json" \
    --argjson custom_dns_rules "$custom_dns_rules_json" \
    --argjson auto_redirect "${OS_AUTO_REDIRECT:-false}" \
    --arg tun_name "${OS_TUN_INTERFACE:-}" \
    --argjson dashboard_enabled "$dashboard_enabled" \
    --arg clash_bind "$CLASH_API_BIND" \
    --arg clash_ui_dir "$CLASH_UI_DIR" \
    '
    {
      log: { level: "info" },
      dns: {
        servers: [
          { type: "tls", tag: "cloudflare", server: "1.1.1.1" },
          { type: "tls", tag: "google", server: "8.8.8.8" },
          { type: "local", tag: "local" }
        ],
        rules: $custom_dns_rules,
        final: "cloudflare"
      },
      inbounds: [
        (
          {
            type: "tun",
            tag: "tun-in",
            address: ["198.18.0.1/30"],
            auto_route: true,
            auto_redirect: $auto_redirect,
            strict_route: true,
            mtu: 1500,
            stack: "system"
          }
          + (if $tun_name != "" then {interface_name: $tun_name} else {} end)
        )
      ],
      outbounds: (
        [{ type: "selector", tag: "proxy", outbounds: (["auto"] + $tags + ["direct"]), default: "auto" }]
        + [{ type: "urltest", tag: "auto", outbounds: $tags, url: "https://www.gstatic.com/generate_204", interval: "3m", tolerance: 50 }]
        + $proxies
        + [{ type: "direct", tag: "direct" }]
      ),
      route: {
        auto_detect_interface: true,
        default_domain_resolver: "cloudflare",
        rules: ([{ action: "sniff" }, { protocol: "dns", action: "hijack-dns" }] + $custom_rules),
        final: "proxy"
      }
    }
    + (
      if $dashboard_enabled then
        {
          experimental: {
            clash_api: {
              external_controller: $clash_bind,
              external_ui: $clash_ui_dir,
              external_ui_download_url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip",
              external_ui_download_detour: "direct",
              secret: "",
              default_mode: "rule"
            }
          }
        }
      else
        {}
      end
    )
    ' > "$tmp_config"

  run_root install -d -m 0755 "$CONFIG_DIR"

  if [[ "$dashboard_enabled" == "true" ]]; then
    run_root install -d -m 0755 "$CLASH_UI_DIR"
  fi

  # Periodic refresh (see os_subscription_timer_*) re-downloads the subscription and
  # calls back in here every $SUBSCRIPTION_REFRESH_SEC — if the server list is the same
  # bytes as last time, skip the backup+install+restart so sing-box doesn't drop active
  # connections on ticks where nothing actually changed. Sets SUBSCRIPTION_CONFIG_CHANGED
  # for the caller.
  SUBSCRIPTION_CONFIG_CHANGED="true"
  if run_root test -f "$CONFIG_FILE" && run_root cmp -s "$tmp_config" "$CONFIG_FILE"; then
    SUBSCRIPTION_CONFIG_CHANGED="false"
    rm -f "$tmp_config"
    return
  fi

  if run_root test -f "$CONFIG_FILE"; then
    backup_file="${CONFIG_DIR}/config.backup-$(date +%Y%m%d-%H%M%S).json"
    run_root cp "$CONFIG_FILE" "$backup_file"
    log "Previous config backup: $backup_file"
  fi

  run_root install -m 0600 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"
}

# Shared by configure_vpn's "subscription" input type and the standalone
# `subscribe` command. dashboard_enabled must already be decided by the
# caller (interactively, or carried over from a previously saved
# subscription) — it is never turned on implicitly.
configure_subscription() {
  local url="$1"
  local dashboard_enabled="${2:-false}"

  ensure_runtime_dependencies
  ensure_cmd jq sing-box curl base64
  os_check_cmds

  log "Downloading subscription..."
  local text server_count
  text="$(fetch_subscription_url "$url")"

  build_outbounds_from_subscription "$text"
  server_count="$(jq 'length' <<<"$SUBSCRIPTION_TAGS_JSON")"
  log "Parsed servers: $server_count"

  write_subscription_config "$dashboard_enabled"
  os_service_write

  local tmp_state
  tmp_state="$(mktemp)"
  jq -n \
    --arg url "$url" \
    --argjson count "$server_count" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson dashboard_enabled "$dashboard_enabled" \
    --arg clash_api_bind "$CLASH_API_BIND" \
    '{url: $url, proxy_count: $count, fetched_at: $fetched_at, dashboard_enabled: $dashboard_enabled, clash_api_bind: $clash_api_bind}' > "$tmp_state"
  run_root install -d -m 0755 "$CONFIG_DIR"
  run_root install -m 0600 "$tmp_state" "$SUBSCRIPTION_STATE_FILE"
  rm -f "$tmp_state"

  # Subscription mode is always full-tunnel; drop any leftover selected-users state/rules.
  run_root rm -f "$STATE_FILE"
  clear_selected_routing
  clear_legacy_sing_box_routing
  remove_custom_nft_files

  os_service_reload
  os_service_enable >/dev/null
  run_root /usr/local/bin/sing-box check -c "$CONFIG_FILE"

  # Only restart (and drop active connections) when the config actually changed, or
  # when sing-box isn't already running — matters for the periodic refresh timer,
  # which calls this every $SUBSCRIPTION_REFRESH_SEC even if the server list is stable.
  if [[ "$SUBSCRIPTION_CONFIG_CHANGED" == "true" ]] || ! os_service_is_active; then
    os_service_restart
    sleep 2
  else
    log "Subscription unchanged ($server_count servers) — kept the running connection"
  fi

  os_subscription_timer_write "$SUBSCRIPTION_REFRESH_SEC"
  os_subscription_timer_enable

  if os_service_is_active; then
    log "Subscription applied ($server_count servers). Background refresh every ${SUBSCRIPTION_REFRESH_SEC}s."
    if [[ "$dashboard_enabled" == "true" ]]; then
      echo "[INFO] Dashboard: http://${CLASH_API_BIND}/ui/ (reachable only from ${CLASH_API_BIND%%:*})"
    else
      echo "[INFO] Dashboard is disabled. Enable it via: $(basename "$0") reconfigure"
    fi
  else
    die "sing-box failed to start. Run: $(basename "$0") logs"
  fi
}

# `vpnc subscribe [url]` — refreshes a previously saved subscription (reusing
# its saved dashboard preference) or, given a fresh URL with no prior
# subscription on file, asks once whether to enable the dashboard.
subscribe_vpn() {
  ensure_runtime_dependencies
  ensure_cmd jq sing-box curl base64
  os_check_cmds

  local url="${1:-}" dashboard_enabled="false"
  local have_state="0"
  run_root test -f "$SUBSCRIPTION_STATE_FILE" && have_state="1"

  if [[ -z "$url" ]]; then
    [[ "$have_state" == "1" ]] || die "No saved subscription. Usage: $(basename "$0") subscribe <url>"
    url="$(run_root jq -r '.url // empty' "$SUBSCRIPTION_STATE_FILE")"
    dashboard_enabled="$(run_root jq -r '.dashboard_enabled // false' "$SUBSCRIPTION_STATE_FILE")"
    CLASH_API_BIND="$(run_root jq -r --arg d "$CLASH_API_BIND" '.clash_api_bind // $d' "$SUBSCRIPTION_STATE_FILE")"
    [[ -n "$url" ]] || die "No saved subscription. Usage: $(basename "$0") subscribe <url>"
  elif [[ "$have_state" == "1" ]]; then
    dashboard_enabled="$(run_root jq -r '.dashboard_enabled // false' "$SUBSCRIPTION_STATE_FILE")"
    CLASH_API_BIND="$(run_root jq -r --arg d "$CLASH_API_BIND" '.clash_api_bind // $d' "$SUBSCRIPTION_STATE_FILE")"
  else
    dashboard_enabled="$(select_dashboard_enabled)"
    [[ "$dashboard_enabled" == "true" ]] && CLASH_API_BIND="$(select_clash_api_bind)"
  fi

  configure_subscription "$url" "$dashboard_enabled"
}

cmd_rules_edit() {
  seed_rules_file_if_missing
  local editor="${EDITOR:-nano}"
  local tmp
  tmp="$(mktemp)"
  run_root cat "$RULES_FILE" > "$tmp"
  "$editor" "$tmp"
  jq -e . "$tmp" >/dev/null 2>&1 || die "Invalid JSON, changes were not saved"
  run_root install -m 0644 "$tmp" "$RULES_FILE"
  rm -f "$tmp"
  log "Rules saved. Apply with: $(basename "$0") rules apply"
}

cmd_rules_list() {
  seed_rules_file_if_missing
  run_root jq -r '.rules[] | "  [\(if .switch then "on " else "off" end)] \(.name)"' "$RULES_FILE"
}

cmd_rules_toggle() {
  local name="${1:-}" state="${2:-}" val tmp
  [[ -n "$name" && ( "$state" == "on" || "$state" == "off" ) ]] \
    || die "Usage: $(basename "$0") rules toggle <name> on|off"

  seed_rules_file_if_missing

  run_root jq -e --arg name "$name" '.rules | any(.name == $name)' "$RULES_FILE" >/dev/null \
    || die "Rule not found: $name (see: $(basename "$0") rules list)"

  [[ "$state" == "on" ]] && val=true || val=false
  tmp="$(mktemp)"
  run_root jq --arg name "$name" --argjson val "$val" '
    (.rules[] | select(.name == $name) | .switch) = $val
  ' "$RULES_FILE" > "$tmp"
  run_root install -m 0644 "$tmp" "$RULES_FILE"
  rm -f "$tmp"
  log "Rule '$name' -> $state. Apply with: $(basename "$0") rules apply"
}

# `rules import <path|url>` — replaces the rules file with a validated {"rules": [...]}
# JSON (keeping a timestamped backup of the previous one). Needed because the seed
# variables only apply while the rules file does not exist yet.
cmd_rules_import() {
  local src="${1:-}" tmp count backup
  [[ -n "$src" ]] || die "Usage: $(basename "$0") rules import <path|url>"

  tmp="$(mktemp)"
  case "$src" in
    http://*|https://*)
      curl -fsSL --max-time 20 "$src" -o "$tmp" || die "Could not download rules: $src"
      ;;
    *)
      [[ -f "$src" ]] || die "File does not exist: $src"
      cp "$src" "$tmp"
      ;;
  esac

  jq -e '.rules and (.rules | type == "array")' "$tmp" >/dev/null 2>&1 \
    || die "Not valid JSON of the form {\"rules\": [...]}: $src"
  count="$(jq '.rules | length' "$tmp")"

  run_root install -d -m 0755 "$CONFIG_DIR"
  if run_root test -f "$RULES_FILE"; then
    backup="${RULES_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
    run_root cp "$RULES_FILE" "$backup"
    log "Previous rules backup: $backup"
  fi

  run_root install -m 0644 "$tmp" "$RULES_FILE"
  rm -f "$tmp"
  log "Imported $count rule groups from $src. Apply with: $(basename "$0") rules apply"
}

cmd_rules_apply() {
  ensure_cmd jq
  run_root test -f "$CONFIG_FILE" || die "Configure the VPN first: $(basename "$0") configure or subscribe <url>"

  local custom_rules_json custom_dns_rules_json tmp
  custom_rules_json="$(compile_custom_rules)"
  custom_dns_rules_json="$(compile_custom_dns_rules)"
  tmp="$(mktemp)"

  run_root jq --argjson custom "$custom_rules_json" --argjson custom_dns "$custom_dns_rules_json" '
    .route.rules = ([{action: "sniff"}, {protocol: "dns", action: "hijack-dns"}] + $custom)
    | .dns.rules = $custom_dns
    | if (.dns.servers | any(.tag == "local")) then . else .dns.servers += [{type: "local", tag: "local"}] end
  ' "$CONFIG_FILE" > "$tmp" || die "Could not apply rules to the current config"

  run_root install -m 0600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"

  run_root /usr/local/bin/sing-box check -c "$CONFIG_FILE" \
    || die "New config failed sing-box validation, restore from a .backup-*.json"
  os_service_restart
  log "Rules applied and sing-box restarted"
}

detect_public_ip() {
  local current_ip
  current_ip=""

  ensure_runtime_dependencies

  if command -v curl >/dev/null 2>&1; then
    current_ip="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$current_ip" ]] || current_ip="$(curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    [[ -n "$current_ip" ]] || current_ip="$(curl -fsSL --max-time 8 https://2ip.ru 2>/dev/null || true)"
  fi

  echo "$current_ip"
}

show_status_summary() {
  local current_ip mode include_uids users dashboard_enabled clash_api_bind

  current_ip="$(detect_public_ip)"
  mode="unknown"
  users=""
  dashboard_enabled="false"
  clash_api_bind="$CLASH_API_BIND"

  if run_root test -f "$SUBSCRIPTION_STATE_FILE"; then
    mode="subscription"
    dashboard_enabled="$(run_root jq -r '.dashboard_enabled // false' "$SUBSCRIPTION_STATE_FILE")"
    clash_api_bind="$(run_root jq -r --arg d "$CLASH_API_BIND" '.clash_api_bind // $d' "$SUBSCRIPTION_STATE_FILE")"
  elif run_root test -f "$STATE_FILE"; then
    mode="$(run_root jq -r '.user_scope // "unknown"' "$STATE_FILE")"
    include_uids="$(run_root jq -c '.include_uids // []' "$STATE_FILE")"
    if [[ "$include_uids" != "[]" ]]; then
      users="$(run_root jq -r '.include_uids | map(tostring) | join(", ")' "$STATE_FILE")"
    fi
    dashboard_enabled="$(run_root jq -r '.dashboard_enabled // false' "$STATE_FILE")"
    clash_api_bind="$(run_root jq -r --arg d "$CLASH_API_BIND" '.clash_api_bind // $d' "$STATE_FILE")"
  fi

  echo
  echo "VPN summary:"
  if [[ -n "$current_ip" ]]; then
    echo "  Public IP: $current_ip"
  else
    echo "  Public IP: unavailable"
  fi
  echo "  Mode: $mode"
  if [[ -n "$users" ]]; then
    echo "  Routed UIDs: $users"
  fi

  if [[ "$mode" == "subscription" ]] && run_root test -f "$SUBSCRIPTION_STATE_FILE"; then
    echo "  Subscription URL: $(run_root jq -r '.url' "$SUBSCRIPTION_STATE_FILE")"
    echo "  Servers: $(run_root jq -r '.proxy_count' "$SUBSCRIPTION_STATE_FILE")"
    echo "  Last fetched: $(run_root jq -r '.fetched_at' "$SUBSCRIPTION_STATE_FILE")"
    echo "  Auto-refresh: $(os_subscription_timer_status)"
  fi

  if [[ "$mode" != "unknown" ]]; then
    if [[ "$dashboard_enabled" == "true" ]]; then
      echo "  Dashboard: http://${clash_api_bind}/ui/"
    else
      echo "  Dashboard: disabled (enable via: $(basename "$0") reconfigure)"
    fi
  fi
}

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat <<HELP_EOF
Usage: ${cmd} <command>

Commands:
  configure          Interactive setup: single server (vless:// / ss:// / JSON) or a
                     subscription (multiple servers). Also asks about the direct-vs-VPN
                     rules file (skip / a well-known local path / a URL / a file path)
                     and whether to enable the web dashboard.
  reconfigure        Same as configure
  subscribe [url]    Fetch/refresh a subscription non-interactively, reusing the
                     dashboard on/off choice saved from configure. With no prior
                     subscription on file, asks once whether to enable the dashboard.
                     Also (re)installs the background auto-refresh timer (see below).
  rules edit         Edit the direct-vs-VPN rules file (\$EDITOR, default nano)
  rules import <path|url>   Replace the rules file from a {"rules": [...]} JSON
  rules list         Show rule groups and their on/off state
  rules toggle <name> on|off   Flip a rule group without opening the editor
  rules apply        Recompile rules into sing-box and restart the service
  status             Show service status
  start              Start VPN service
  stop               Stop VPN service
  restart            Restart VPN service
  enable             Enable autostart on boot
  disable            Disable autostart on boot
  uninstall          Completely remove sing-box and all configurations
  logs               Follow sing-box logs
  show-config        Print /etc/sing-box/config.json
  show-state         Print /etc/sing-box/vpnc-state.json
  help               Show this help

Web dashboard:
  The Clash-style dashboard (server list, ping/speed test, manual pick or
  "auto"-fastest) is off by default and only turns on if you answer "yes" to
  "Enable web dashboard?" during configure/subscribe — you're then also asked for the
  bind address (IP:port), with VPNC_CLASH_API_BIND / CLASH_API_BIND's built-in default
  (see the top of this script) offered as a suggestion. Once enabled it's served at
  http://<bind>/ui/.

Direct-vs-VPN rules:
  \$RULES_FILE ($RULES_FILE) starts out empty — nothing bypasses the VPN until you add
  rule groups yourself (${cmd} rules edit/toggle). To seed it from a JSON file instead,
  set VPNC_RULES_SEED_PATH=<local path> or VPNC_RULES_SEED_URL=<url> (format:
  {"rules": [...]}) before the first "rules" command runs; leave both unset to skip
  seeding entirely.

Subscription auto-refresh:
  Once a subscription is active (configure's option 3, or "subscribe"), it is
  re-downloaded every ${SUBSCRIPTION_REFRESH_SEC}s in the background (systemd timer on
  Linux, launchd on macOS) so server changes on the provider's side show up without you
  running "subscribe" by hand. sing-box is only restarted (dropping active connections)
  when the refreshed server list actually differs from what's running — an unchanged
  refresh is a no-op. Override the interval with VPNC_SUBSCRIPTION_REFRESH_SEC (seconds)
  before running configure/subscribe. Switching back to single-server mode removes the
  timer automatically.
HELP_EOF
}

uninstall_vpn() {
  ensure_runtime_dependencies
  echo "[WARN] This will completely remove sing-box and all its configurations!"
  echo "[WARN] The following will be deleted:"
  echo "  - /usr/local/bin/sing-box"
  echo "  - /etc/sing-box/"
  echo "  - $(os_service_file)"
  echo "  - subscription refresh timer (if a subscription is active)"
  echo "  - /usr/local/bin/vpnc"
  echo "  - /usr/local/bin/makrelbka-vpnc"
  echo "  - /usr/local/lib/vpnc/"
  echo
  read -r -p "Are you absolutely sure? Type 'yes' to continue: " confirmation

  if [[ "$confirmation" != "yes" ]]; then
    echo "Uninstall cancelled."
    return
  fi

  echo "Stopping and disabling sing-box service..."
  os_service_stop 2>/dev/null || true
  os_service_disable 2>/dev/null || true

  echo "Stopping subscription refresh timer..."
  os_subscription_timer_disable 2>/dev/null || true
  os_subscription_timer_remove 2>/dev/null || true

  echo "Clearing routing runtime rules..."
  clear_selected_routing
  clear_legacy_sing_box_routing

  echo "Removing service file..."
  os_service_remove
  os_service_reload

  echo "Removing sing-box binary..."
  run_root rm -f /usr/local/bin/sing-box

  echo "Removing configuration directory..."
  run_root rm -rf /etc/sing-box

  echo "Removing manager script..."
  run_root rm -f /usr/local/bin/vpnc /usr/local/bin/makrelbka-vpnc
  run_root rm -rf /usr/local/lib/vpnc

  echo "[SUCCESS] sing-box has been completely uninstalled."
  echo "You may want to reboot your system to clean up any remaining TUN interfaces."
}
