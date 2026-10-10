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

# Failover watcher (`vpnc _tick`, run by the same background job as the subscription
# refresh). The tick fires every WATCH_INTERVAL_SEC; the subscription itself is only
# re-fetched every SUBSCRIPTION_REFRESH_SEC. clash_api without the web UI listens on
# VPNC_CONTROL_BIND (loopback) with a random secret kept in the subscription state file.
WATCH_INTERVAL_SEC="${VPNC_WATCH_SEC:-20}"
WATCH_FAIL_TICKS="${VPNC_WATCH_FAIL_TICKS:-2}"
WATCH_OK_TICKS="${VPNC_WATCH_OK_TICKS:-2}"
CONTROL_BIND_DEFAULT="${VPNC_CONTROL_BIND:-127.0.0.1:9099}"
WATCH_FILE="${CONFIG_DIR}/vpnc-watch.json"
PROBE_URL="https://www.gstatic.com/generate_204"
# Copy of the config sing-box was last (re)started with. A subscription refresh compares the
# new config against it to decide whether a restart (which drops every connection) is needed.
RUNNING_FILE="${CONFIG_DIR}/config.running.json"

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

# Optional "priority server" step of the wizard (see cmd_primary). Needs the parsed server
# list, so it runs after the subscription is downloaded. Enter = no priority server, or
# keep the current one when reconfiguring; 0 clears it. Sets SUB_PRIMARY.
select_primary_server() {
  local current="$SUB_PRIMARY" tags n=0 tag choice default_label
  tags="$(jq -r '.[]' <<<"$SUBSCRIPTION_TAGS_JSON")"
  echo >&2
  echo "Priority server (optional, advanced: stay on it, fall back to others if it fails, return when it is back):" >&2
  while IFS= read -r tag; do
    n=$((n + 1))
    printf '  %2d) %s\n' "$n" "$tag" >&2
  done <<<"$tags"
  if [[ -n "$current" ]]; then default_label="keep current: ${current}"; else default_label="none"; fi
  read -r -p "Enter number [1-${n}], 0 = none (default: ${default_label}): " choice
  if [[ -z "$choice" ]]; then
    return
  elif [[ "$choice" == "0" ]]; then
    SUB_PRIMARY=""
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
    SUB_PRIMARY="$(sed -n "${choice}p" <<<"$tags")"
  else
    warn "Invalid choice, leaving the priority server as is"
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
  [[ -n "${home:-}" ]] || home="${HOME:-/root}"
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

  # One question at a time: choose a format, paste it right away, only then move on to
  # rules, users and the dashboard.
  input_type="$(select_input_type)"
  mode=""
  case "$input_type" in
    subscription)
      ensure_cmd curl base64
      sub_url="$(read_subscription_url)"
      ;;
    url)
      echo
      read -r -p "Paste VPN URL: " uri
      uri_scheme="$(detect_uri_scheme "$uri")"
      [[ "$uri_scheme" != "unknown" ]] || die "Unsupported URI scheme. Expected vless:// or ss://"
      outbound="$(build_outbound_from_uri "$uri")"
      ;;
    *)
      mode="$(select_mode)"
      json_payload="$(read_json_payload)"
      outbound="$(build_outbound_from_json "$json_payload" "$mode")"
      ;;
  esac

  # Asked once here (never during the unattended `subscribe` background refresh) so it
  # covers both the single-server and subscription paths.
  select_rules_source

  if [[ "$input_type" == "subscription" ]]; then
    dashboard_enabled="$(select_dashboard_enabled)"
    [[ "$dashboard_enabled" == "true" ]] && CLASH_API_BIND="$(select_clash_api_bind)"
    configure_subscription "$sub_url" "$dashboard_enabled" ask_primary
    return
  fi

  user_scope="$(select_user_scope)"
  include_uids_json='[]'

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
  restart_service
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
  raw="$(curl -fsSL --compressed --max-time 20 "$url")" || die "Could not download subscription: $url"
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
    curl -fsSL --compressed --max-time 20 "$RULES_SEED_URL" -o "$tmp" || die "Could not download rules seed: $RULES_SEED_URL"
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
    --arg primary "$SUB_PRIMARY" \
    --arg control_bind "$SUB_CONTROL_BIND" \
    --arg control_secret "$SUB_CONTROL_SECRET" \
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
        [{ type: "selector", tag: "proxy", outbounds: (["auto"] + $tags + ["direct"]), default: (if ($primary != "" and ($tags | index($primary))) then $primary else "auto" end) }]
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
    # clash_api is always on in subscription mode: vpnc itself uses it to ping servers and
    # switch the selector (see cmd_tick). The web UI part stays opt-in.
    + {
      experimental: {
        clash_api: (
          { external_controller: $control_bind, secret: $control_secret, default_mode: "rule" }
          + (
            if $dashboard_enabled then
              {
                external_ui: $clash_ui_dir,
                external_ui_download_url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip",
                external_ui_download_detour: "direct"
              }
            else
              {}
            end
          )
        )
      }
    }
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
  SUBSCRIPTION_RESTART_NEEDED="true"
  if run_root test -f "$CONFIG_FILE" && run_root cmp -s "$tmp_config" "$CONFIG_FILE"; then
    SUBSCRIPTION_CONFIG_CHANGED="false"
    SUBSCRIPTION_RESTART_NEEDED="false"
    rm -f "$tmp_config"
    return
  fi
  # A changed file does not always need a restart: if the servers in use are untouched the
  # new config is only written to disk and takes effect at the next restart.
  config_restart_needed "$tmp_config" || SUBSCRIPTION_RESTART_NEEDED="false"

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
  local ask_primary="${3:-}"

  ensure_runtime_dependencies
  ensure_cmd jq sing-box curl base64
  os_check_cmds

  load_subscription_extras "$dashboard_enabled"

  log "Downloading subscription..."
  local text server_count
  text="$(fetch_subscription_url "$url")"

  build_outbounds_from_subscription "$text"
  server_count="$(jq 'length' <<<"$SUBSCRIPTION_TAGS_JSON")"
  log "Parsed servers: $server_count"
  [[ "$ask_primary" == "ask_primary" ]] && select_primary_server

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
    --argjson fetched_epoch "$(date +%s)" \
    --arg primary "$SUB_PRIMARY" \
    --arg api_secret "$SUB_API_SECRET" \
    --arg control_bind "$SUB_CONTROL_BIND" \
    --arg control_secret "$SUB_CONTROL_SECRET" \
    '{url: $url, proxy_count: $count, fetched_at: $fetched_at, fetched_epoch: $fetched_epoch, dashboard_enabled: $dashboard_enabled, clash_api_bind: $clash_api_bind, primary: $primary, api_secret: $api_secret, control_bind: $control_bind, control_secret: $control_secret}' > "$tmp_state"
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
  if [[ "$SUBSCRIPTION_RESTART_NEEDED" == "true" ]] || ! os_service_is_active; then
    restart_service
    sleep 2
  elif [[ "$SUBSCRIPTION_CONFIG_CHANGED" == "true" ]]; then
    log "Subscription updated ($server_count servers) — servers in use unchanged, kept the running connection (new list applies at the next restart)"
  else
    log "Subscription unchanged ($server_count servers) — kept the running connection"
  fi

  # Skip when already on: this same function runs every time the background timer
  # fires `vpnc subscribe` on itself, and os_subscription_timer_enable() bootouts +
  # reloads the launchd/systemd job — doing that from inside the job's own running
  # instance is a self-unload race that can leave the timer not reloaded. Only
  # (re)provision when it's actually missing (first run, or after `configure` switched
  # back from single-server mode).
  # Installs from before the failover watcher have a job that runs `subscribe`; an
  # interactive run swaps it for `_tick` (never from the job itself: VPNC_FROM_TIMER).
  if [[ "$(os_subscription_timer_status)" == "off" ]] \
    || { [[ -z "${VPNC_FROM_TIMER:-}" ]] && ! run_root grep -q '_tick' "$SUBSCRIPTION_SERVICE_FILE" 2>/dev/null; }; then
    os_subscription_timer_write "$WATCH_INTERVAL_SEC"
    os_subscription_timer_enable
  fi

  if os_service_is_active; then
    local timer_status
    timer_status="$(os_subscription_timer_status)"
    if [[ "$timer_status" == "off" ]]; then
      warn "Background refresh timer is NOT enabled — subscription will not auto-update."
      warn "To fix: run with sudo, e.g.  sudo $(basename "$0") subscribe"
    else
      log "Subscription applied ($server_count servers). Background refresh $timer_status."
    fi
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

# ---------------------------------------------------------------------------
# Failover watcher. Optional "priority config" (`vpnc primary <name>`): the selector
# `proxy` sits on that server; the background tick pings servers through sing-box's
# clash_api and, when the priority server stops answering, first looks for an updated
# config of that location in the subscription, then falls back to the fastest live
# server and returns to the priority one as soon as it is alive again. Without a
# priority server the tick only refreshes the subscription.
# ---------------------------------------------------------------------------

# Sets SUB_PRIMARY / SUB_API_SECRET / SUB_CONTROL_BIND / SUB_CONTROL_SECRET from the saved
# subscription state (so a refresh keeps the choice and doesn't churn the config bytes).
load_subscription_extras() {
  local dashboard_enabled="${1:-false}"
  SUB_PRIMARY=""
  SUB_API_SECRET=""
  if run_root test -f "$SUBSCRIPTION_STATE_FILE"; then
    SUB_PRIMARY="$(run_root jq -r '.primary // ""' "$SUBSCRIPTION_STATE_FILE")"
    SUB_API_SECRET="$(run_root jq -r '.api_secret // ""' "$SUBSCRIPTION_STATE_FILE")"
  fi
  [[ -n "$SUB_API_SECRET" ]] || SUB_API_SECRET="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

  if [[ "$dashboard_enabled" == "true" ]]; then
    SUB_CONTROL_BIND="$CLASH_API_BIND"
    SUB_CONTROL_SECRET=""
  else
    SUB_CONTROL_BIND="$CONTROL_BIND_DEFAULT"
    SUB_CONTROL_SECRET="$SUB_API_SECRET"
  fi
}

# api_call METHOD PATH [JSON_BODY] — talks to the running sing-box clash_api.
api_call() {
  local method="$1" path="$2" body="${3:-}" bind secret
  bind="$(run_root jq -r '.control_bind // empty' "$SUBSCRIPTION_STATE_FILE")"
  secret="$(run_root jq -r '.control_secret // ""' "$SUBSCRIPTION_STATE_FILE")"
  [[ -n "$bind" ]] || return 1
  if [[ -n "$body" ]]; then
    curl -fsS --max-time 8 -X "$method" -H "Authorization: Bearer ${secret}" \
      -H 'Content-Type: application/json' -d "$body" "http://${bind}${path}"
  else
    curl -fsS --max-time 8 -X "$method" -H "Authorization: Bearer ${secret}" "http://${bind}${path}"
  fi
}

uri_encode() {
  jq -rn --arg v "$1" '$v | @uri'
}

# Real server tags (no selector/urltest/direct) from the running config, one per line.
subscription_tags() {
  run_root jq -r '.outbounds[] | select(.type | IN("selector", "urltest", "direct") | not) | .tag' "$CONFIG_FILE"
}

# Delay in ms through one server, or 0 when it does not answer.
probe_delay() {
  local out
  out="$(api_call GET "/proxies/$(uri_encode "$1")/delay?url=$(uri_encode "$PROBE_URL")&timeout=4000" 2>/dev/null)" || { echo 0; return; }
  jq -r '.delay // 0' <<<"$out" 2>/dev/null || echo 0
}

# probe_all DIR — writes DIR/<n> = "<delay>\t<tag>" for every server, 8 probes at a time.
probe_all() {
  local dir="$1" n=0 tag
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    n=$((n + 1))
    ( printf '%s\t%s\n' "$(probe_delay "$tag")" "$tag" > "$dir/$n" ) &
    (( n % 8 )) || wait
  done < <(subscription_tags)
  wait
}

restart_service() {
  os_service_restart
  run_root install -m 0600 "$CONFIG_FILE" "$RUNNING_FILE" 2>/dev/null || true
}

# active_leaf — the server traffic goes through right now (selector choice, or its urltest
# pick when on "auto"). Fails when clash_api is unreachable.
active_leaf() {
  local now leaf
  now="$(api_call GET /proxies/proxy 2>/dev/null | jq -r '.now // empty' 2>/dev/null)" || return 1
  [[ -n "$now" ]] || return 1
  leaf="$now"
  if [[ "$now" == "auto" ]]; then
    leaf="$(api_call GET /proxies/auto 2>/dev/null | jq -r '.now // empty' 2>/dev/null)" || return 1
  fi
  [[ -n "$leaf" ]] || return 1
  echo "$leaf"
}

# config_restart_needed NEW_CONFIG — exit 0 (restart) unless it is certain that only the
# server list changed. Server definitions are NOT a reason to restart: providers rotate
# tls/reality parameters every few minutes, and a running connection keeps working with the
# definition it started with. Changed definitions wait on disk until the server stops
# answering (cmd_tick -> watch_apply_pending) or until the next restart. Everything outside
# `outbounds` (dns, route rules, inbounds, clash_api) changing needs a restart. Any doubt
# (no baseline, service down, jq error) means restart.
config_restart_needed() {
  local new="$1" old="$RUNNING_FILE" res
  run_root test -f "$old" || old="$CONFIG_FILE"
  run_root test -f "$old" || return 0
  os_service_is_active || return 0
  res="$(run_root jq -n --slurpfile o "$old" --slurpfile n "$new" \
    '($o[0] | del(.outbounds)) != ($n[0] | del(.outbounds))' 2>/dev/null)" || return 0
  [[ "$res" == "false" ]] && return 1
  return 0
}

# config_pending — the config on disk differs from what sing-box was started with.
config_pending() {
  run_root test -f "$RUNNING_FILE" && ! run_root cmp -s "$CONFIG_FILE" "$RUNNING_FILE"
}

watch_get() {
  local key="$1" default="$2" v=""
  if run_root test -f "$WATCH_FILE"; then
    v="$(run_root jq -r --arg k "$key" '.[$k] // empty | tostring' "$WATCH_FILE" 2>/dev/null || true)"
  fi
  echo "${v:-$default}"
}

# watch_save FAIL OK FAILOVER REFRESHED  (other keys, e.g. last_attempt, are kept)
watch_save() {
  local tmp base
  tmp="$(mktemp)"
  base='{}'
  run_root test -f "$WATCH_FILE" && base="$(run_root cat "$WATCH_FILE")"
  jq -n --argjson base "$base" --argjson fail "$1" --argjson ok "$2" --argjson failover "$3" --argjson refreshed "$4" \
    '$base + {fail: $fail, ok: $ok, failover: $failover, refreshed: $refreshed}' > "$tmp"
  run_root install -m 0600 "$tmp" "$WATCH_FILE"
  rm -f "$tmp"
}

# watch_set KEY JSON_VALUE
watch_set() {
  local tmp base
  tmp="$(mktemp)"
  base='{}'
  run_root test -f "$WATCH_FILE" && base="$(run_root cat "$WATCH_FILE")"
  jq -n --argjson base "$base" --arg k "$1" --argjson v "$2" '$base + {($k): $v}' > "$tmp"
  run_root install -m 0600 "$tmp" "$WATCH_FILE"
  rm -f "$tmp"
}

watch_mark_attempt() {
  watch_set last_attempt "$(date +%s)"
}

# Re-fetch the subscription when SUBSCRIPTION_REFRESH_SEC passed since the last fetch or
# attempt (failed fetches are retried at the same pace, not every tick). $1 = "force".
watch_refresh() {
  local force="${1:-}" now last fetched
  now="$(date +%s)"
  fetched="$(run_root jq -r '.fetched_epoch // 0' "$SUBSCRIPTION_STATE_FILE")"
  last="$(watch_get last_attempt 0)"
  (( fetched > last )) && last="$fetched"
  if [[ "$force" != "force" ]] && (( now - last < SUBSCRIPTION_REFRESH_SEC )); then
    return 0
  fi
  watch_mark_attempt
  # Background subshell + wait: keeps `set -e` active inside subscribe_vpn (a plain
  # `( ... ) || warn` would switch it off and e.g. a failed `sing-box check` would not stop the restart).
  ( subscribe_vpn ) &
  wait $! || warn "Subscription refresh failed; keeping the running config"
}

# switch_to TAG REASON
switch_to() {
  api_call PUT /proxies/proxy "$(jq -cn --arg n "$1" '{name: $n}')" >/dev/null \
    && log "Failover: switched to '$1' ($2)" \
    || warn "Could not switch to '$1' via clash_api"
}

# best_alive DIR EXCLUDE... — fastest tag with delay > 0 not in EXCLUDE.
best_alive() {
  local dir="$1" best="" best_ms=0 f ms tag ex skip
  shift
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    IFS=$'\t' read -r ms tag < "$f"
    (( ms > 0 )) || continue
    skip=0
    for ex in "$@"; do [[ "$tag" == "$ex" ]] && skip=1; done
    (( skip )) && continue
    if [[ -z "$best" ]] || (( ms < best_ms )); then best="$tag"; best_ms="$ms"; fi
  done
  echo "$best"
}

delay_in_dir() {
  local dir="$1" want="$2" f ms tag
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    IFS=$'\t' read -r ms tag < "$f"
    [[ "$tag" == "$want" ]] && { echo "$ms"; return; }
  done
  echo 0
}

watch_failover() {
  local primary now dir fail ok failover refreshed p_ms now_ms alt
  primary="$(run_root jq -r '.primary // ""' "$SUBSCRIPTION_STATE_FILE")"
  [[ -n "$primary" ]] || return 0

  now="$(api_call GET /proxies/proxy 2>/dev/null | jq -r '.now // empty' 2>/dev/null)" || return 0
  [[ -n "$now" ]] || return 0   # sing-box not up (restarting) — try again next tick

  if ! subscription_tags | grep -qxF -- "$primary"; then
    warn "Priority server '$primary' is not in the subscription any more — failover idle"
    return 0
  fi

  dir="$(mktemp -d)"
  probe_all "$dir"
  p_ms="$(delay_in_dir "$dir" "$primary")"
  now_ms="$(delay_in_dir "$dir" "$now")"

  fail="$(watch_get fail 0)"; ok="$(watch_get ok 0)"
  failover="$(watch_get failover false)"; refreshed="$(watch_get refreshed false)"

  if (( p_ms > 0 )); then ok=$((ok + 1)); fail=0; refreshed=false
  else fail=$((fail + 1)); ok=0; fi

  if [[ "$now" == "$primary" ]]; then
    failover=false
    if (( fail >= WATCH_FAIL_TICKS )); then
      if [[ "$refreshed" == "false" ]]; then
        # Maybe the provider already published a new config for this location.
        refreshed=true
        warn "Priority server '$primary' is not answering — refreshing the subscription for an updated config"
        watch_save "$fail" "$ok" "$failover" "$refreshed"
        watch_refresh force
        # A newer definition of this server may be waiting on disk (see config_restart_needed).
        if config_pending; then
          log "Applying the pending config (restart) for '$primary'"
          restart_service
        fi
        rm -rf "$dir"
        return 0
      fi
      alt="$(best_alive "$dir" "$primary")"
      if [[ -n "$alt" ]]; then
        switch_to "$alt" "priority server '$primary' is down"
        failover=true
      else
        warn "Priority server '$primary' is down and no other server answers"
      fi
    fi
  elif [[ "$failover" == "true" ]]; then
    if (( ok >= WATCH_OK_TICKS )); then
      switch_to "$primary" "priority server is back"
      failover=false
    elif (( now_ms <= 0 )); then
      alt="$(best_alive "$dir" "$primary" "$now")"
      [[ -n "$alt" ]] && switch_to "$alt" "'$now' stopped answering"
    fi
  fi
  # now != primary and no failover of ours → the user picked it by hand; leave it.

  watch_save "$fail" "$ok" "$failover" "$refreshed"
  rm -rf "$dir"
}

# `vpnc _tick` — run by the background timer/job. Quiet unless something happens.
cmd_tick() {
  export VPNC_FROM_TIMER=1
  run_root test -f "$SUBSCRIPTION_STATE_FILE" || return 0
  ensure_cmd jq curl
  watch_refresh
  watch_apply_pending
  watch_failover
}

# New server definitions are written to disk without restarting (see config_restart_needed).
# When the server in use stops answering WATCH_FAIL_TICKS ticks in a row, restart onto the
# new config — it may be exactly what fixes it. Only for the no-priority case; with a
# priority server watch_failover handles it.
watch_apply_pending() {
  local leaf n
  [[ -z "$(run_root jq -r '.primary // ""' "$SUBSCRIPTION_STATE_FILE")" ]] || return 0
  if ! config_pending; then watch_set pend_fail 0; return 0; fi
  leaf="$(active_leaf)" || return 0
  if (( $(probe_delay "$leaf") > 0 )); then watch_set pend_fail 0; return 0; fi
  n=$(( $(watch_get pend_fail 0) + 1 ))
  watch_set pend_fail "$n"
  if (( n >= WATCH_FAIL_TICKS )); then
    warn "Server '$leaf' is not answering and a newer config is waiting — restarting onto it"
    restart_service
    watch_set pend_fail 0
  fi
}

# `vpnc primary [name|number|off]` — show / set / clear the priority server.
cmd_primary() {
  local arg="${1:-}" cur tags n=0 tag target="" tmp
  run_root test -f "$SUBSCRIPTION_STATE_FILE" || die "Priority server needs a subscription: $(basename "$0") subscribe <url>"
  ensure_cmd jq
  cur="$(run_root jq -r '.primary // ""' "$SUBSCRIPTION_STATE_FILE")"
  tags="$(subscription_tags)"

  if [[ -z "$arg" ]]; then
    echo "Priority server: ${cur:-(none)}"
    while IFS= read -r tag; do
      n=$((n + 1))
      printf '  %2d) %s%s\n' "$n" "$tag" "$([[ "$tag" == "$cur" ]] && echo '  <- priority')"
    done <<<"$tags"
    echo "Set: $(basename "$0") primary <name|number>   Clear: $(basename "$0") primary off"
    return
  fi

  if [[ "$arg" == "off" ]]; then
    target=""
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    target="$(sed -n "${arg}p" <<<"$tags")"
    [[ -n "$target" ]] || die "No server number $arg"
  else
    grep -qxF -- "$arg" <<<"$tags" || die "No such server: $arg (list: $(basename "$0") primary)"
    target="$arg"
  fi

  tmp="$(mktemp)"
  run_root jq --arg p "$target" '.primary = $p' "$SUBSCRIPTION_STATE_FILE" > "$tmp"
  run_root install -m 0600 "$tmp" "$SUBSCRIPTION_STATE_FILE"
  rm -f "$tmp"
  watch_save 0 0 false false
  if [[ -n "$target" ]]; then log "Priority server: $target"; else log "Priority server cleared"; fi
  # Rewrites the selector default on disk (no restart needed for that alone)...
  subscribe_vpn
  # ...and switches the running selector right away.
  [[ -z "$target" ]] || switch_to "$target" "set as priority"
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
      curl -fsSL --compressed --max-time 20 "$src" -o "$tmp" || die "Could not download rules: $src"
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
  restart_service
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
    if run_root test -f "$RUNNING_FILE" && ! run_root cmp -s "$CONFIG_FILE" "$RUNNING_FILE"; then
      echo "  Config on disk is newer than the running one (applies at next restart: $(basename "$0") restart)"
    fi
    local primary
    primary="$(run_root jq -r '.primary // ""' "$SUBSCRIPTION_STATE_FILE")"
    echo "  Priority server: ${primary:-none} (set: $(basename "$0") primary)"
    if [[ -n "$primary" ]]; then
      echo "  Failover active: $(watch_get failover false), priority fail/ok ticks: $(watch_get fail 0)/$(watch_get ok 0)"
    fi
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
  primary [name|n|off]  Advanced: priority server for a subscription. Shows the list
                     without arguments. See "Priority server" below.
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

Priority server (advanced, subscription mode):
  "${cmd} primary <name|number>" pins one server: the connection goes through it. A
  background tick (every ${WATCH_INTERVAL_SEC}s, VPNC_WATCH_SEC) pings servers via sing-box's clash_api.
  If the priority server stops answering, the subscription is refreshed once to pick up
  an updated config of that location; if it still fails, traffic moves to the fastest
  live server and returns to the priority one as soon as it answers again. "primary off"
  clears it. Without a priority server the tick only refreshes the subscription.
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

  if run_root test -f "$RULES_FILE"; then
    local user_backup
    user_backup="$(default_rules_candidate_path)"
    if [[ -f "$user_backup" ]]; then
      cp "$user_backup" "${user_backup}.backup-$(date +%Y%m%d-%H%M%S)"
    fi
    run_root cp "$RULES_FILE" "$user_backup"
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      run_root chown "$SUDO_USER" "$user_backup" 2>/dev/null || true
    fi
    echo "Saved your routing rules to $user_backup"
    echo "  (next 'configure' will offer to reuse it automatically — option 2 in the rules prompt)"
  fi

  echo "Removing configuration directory..."
  run_root rm -rf /etc/sing-box

  echo "Removing manager script..."
  run_root rm -f /usr/local/bin/vpnc /usr/local/bin/makrelbka-vpnc
  run_root rm -rf /usr/local/lib/vpnc

  echo "[SUCCESS] sing-box has been completely uninstalled."
  echo "You may want to reboot your system to clean up any remaining TUN interfaces."
}
