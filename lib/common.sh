# shellcheck shell=bash
# Shared logic for vpnc: mihomo config generation, URI/subscription parsing,
# rules, prompts. OS-specific pieces (service, deps, routing) live in lib/<os>.sh
# and are called through the os_* / *_selected_routing functions defined there.
# Compatible with bash 3.2 (macOS system bash) — no associative arrays.

export PATH="/usr/local/sbin:/usr/local/bin:/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="/etc/mihomo/config.yaml"
STATE_FILE="/etc/mihomo/vpnc-state.json"
NFT_DIR="/etc/mihomo/nftables.d"
NFT_FILE="${NFT_DIR}/vpnc-selected-users.nft"
SELECTED_MARK_HEX="0x2023"
SELECTED_MARK_NFT="0x00002023"
SELECTED_ROUTE_TABLE="10023"
SELECTED_RULE_PREF="8990"

RULES_FILE="${CONFIG_DIR}/vpnc-rules.json"
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
# How often mihomo re-downloads the saved subscription itself (proxy-providers `interval`).
SUBSCRIPTION_REFRESH_SEC="${VPNC_SUBSCRIPTION_REFRESH_SEC:-300}"
# mihomo's external controller without the web UI listens on VPNC_CONTROL_BIND (loopback)
# with a random secret kept in the state file; vpnc uses it to reload and refresh.
CONTROL_BIND_DEFAULT="${VPNC_CONTROL_BIND:-127.0.0.1:9099}"
MIHOMO_BIN="/usr/local/bin/mihomo"
PROVIDERS_DIR="${CONFIG_DIR}/providers"
PROBE_URL="https://www.gstatic.com/generate_204"
# Torrent-only / whitelist-CDN nodes of the provider, never wanted in the pool (same as clash/gen.py).
SUB_EXCLUDE="Торрент|Белые списки"

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

# ---------------------------------------------------------------------------
# State (/etc/mihomo/vpnc-state.json, 0600): everything the config is rebuilt from, so
# `rules apply`, `primary` and `subscribe <url>` can regenerate it without asking again.
# Fields: mode (single|subscription), user_scope, include_uids, dashboard_enabled,
# clash_api_bind, api_secret, url, primary, proxy (single mode: mihomo proxy object).
# ---------------------------------------------------------------------------

# Loads the state file into ST_* globals (defaults when there is no file yet).
load_state() {
  ST_MODE=""; ST_SCOPE="all"; ST_UIDS='[]'; ST_DASH="false"; ST_BIND="$CLASH_API_BIND"
  ST_SECRET=""; ST_URL=""; ST_PRIMARY=""; ST_PROXY="null"
  run_root test -f "$STATE_FILE" || return 0
  local s
  s="$(run_root cat "$STATE_FILE")"
  ST_MODE="$(jq -r '.mode // ""' <<<"$s")"
  ST_SCOPE="$(jq -r '.user_scope // "all"' <<<"$s")"
  ST_UIDS="$(jq -c '.include_uids // []' <<<"$s")"
  ST_DASH="$(jq -r '.dashboard_enabled // false' <<<"$s")"
  ST_BIND="$(jq -r --arg d "$CLASH_API_BIND" '.clash_api_bind // $d' <<<"$s")"
  ST_SECRET="$(jq -r '.api_secret // ""' <<<"$s")"
  ST_URL="$(jq -r '.url // ""' <<<"$s")"
  ST_PRIMARY="$(jq -r '.primary // ""' <<<"$s")"
  ST_PROXY="$(jq -c '.proxy // null' <<<"$s")"
  # Mode was not stored by older installs: a saved subscription URL means subscription.
  if [[ -z "$ST_MODE" ]]; then
    if [[ -n "$ST_URL" ]]; then ST_MODE="subscription"; else ST_MODE="single"; fi
  fi
}

save_state() {
  local tmp
  [[ -n "$ST_SECRET" ]] || ST_SECRET="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  tmp="$(mktemp)"
  jq -n \
    --arg mode "$ST_MODE" --arg user_scope "$ST_SCOPE" --argjson include_uids "$ST_UIDS" \
    --argjson dashboard_enabled "$ST_DASH" --arg clash_api_bind "$ST_BIND" \
    --arg api_secret "$ST_SECRET" --arg url "$ST_URL" --arg primary "$ST_PRIMARY" \
    --argjson proxy "$ST_PROXY" '
    {mode: $mode, user_scope: $user_scope, include_uids: $include_uids,
     dashboard_enabled: $dashboard_enabled, clash_api_bind: $clash_api_bind,
     api_secret: $api_secret, url: $url, primary: $primary, proxy: $proxy}
  ' > "$tmp"
  run_root install -d -m 0755 "$CONFIG_DIR"
  run_root install -m 0600 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

# Address and secret of mihomo's external controller: the dashboard address without a
# secret when the dashboard is on (it is local, as before), else loopback + random secret.
control_endpoint() {
  if [[ "$ST_DASH" == "true" ]]; then
    CTL_BIND="$ST_BIND"; CTL_SECRET=""
  else
    CTL_BIND="$CONTROL_BIND_DEFAULT"; CTL_SECRET="$ST_SECRET"
  fi
}

# api_call METHOD PATH [JSON_BODY] — talks to the running mihomo.
api_call() {
  local method="$1" path="$2" body="${3:-}"
  load_state
  control_endpoint
  if [[ -n "$body" ]]; then
    curl -fsS --max-time 10 -X "$method" -H "Authorization: Bearer ${CTL_SECRET}" \
      -H 'Content-Type: application/json' -d "$body" "http://${CTL_BIND}${path}"
  else
    curl -fsS --max-time 10 -X "$method" -H "Authorization: Bearer ${CTL_SECRET}" "http://${CTL_BIND}${path}"
  fi
}

# ---------------------------------------------------------------------------
# Config generation. mihomo reads JSON as YAML, so the whole config is one jq program.
# ---------------------------------------------------------------------------

# sb_outbound_to_mihomo — stdin: sing-box outbound (what build_outbound_from_* produce),
# stdout: the same server as a mihomo proxy named SERVER. Only what those parsers emit.
sb_outbound_to_mihomo() {
  jq -c '
    if .type == "vless" then
      ({name: "SERVER", type: "vless", server: .server, port: .server_port, uuid: .uuid,
        udp: true, network: (.transport.type // "tcp")}
       + (if (.flow // "") != "" then {flow: .flow} else {} end)
       + (if .tls.enabled then
            ({tls: true, servername: (.tls.server_name // .server),
              "client-fingerprint": (.tls.utls.fingerprint // "chrome")}
             + (if .tls.alpn then {alpn: .tls.alpn} else {} end)
             + (if .tls.reality.enabled then
                  {"reality-opts": {"public-key": .tls.reality.public_key, "short-id": (.tls.reality.short_id // "")}}
                else {} end))
          else {} end)
       + (if .transport.type == "ws" then
            {"ws-opts": ({path: (.transport.path // "/")}
                         + (if .transport.headers then {headers: .transport.headers} else {} end))}
          else {} end)
       + (if .transport.type == "grpc" then
            {"grpc-opts": {"grpc-service-name": (.transport.service_name // "")}}
          else {} end))
    elif .type == "shadowsocks" then
      {name: "SERVER", type: "ss", server: .server, port: .server_port, cipher: .method, password: .password, udp: true}
    else error("unsupported outbound type: \(.type)") end
  '
}

# JSON array of mihomo rule strings from the rules file (same groups as before: switch,
# `or`, outbound direct/else). "direct" -> DIRECT, anything else -> PROXY.
compile_mihomo_rules() {
  seed_rules_file_if_missing
  run_root jq -c '
    def rtype: {domain: "DOMAIN", domain_suffix: "DOMAIN-SUFFIX", domain_keyword: "DOMAIN-KEYWORD",
                domain_regex: "DOMAIN-REGEX", ip_cidr: "IP-CIDR", port: "DST-PORT", port_range: "DST-PORT",
                process_name: "PROCESS-NAME", network: "NETWORK"};
    def vals($r; $k): [$r[$k][]? | tostring | if $k == "port_range" then gsub(":"; "-") else . end];
    def term($k; $v): (if $k == "ip_cidr" and ($v | contains(":")) then "IP-CIDR6" else rtype[$k] end) + "," + $v;
    def line($k; $v; $t): term($k; $v) + "," + $t + (if $k == "ip_cidr" then ",no-resolve" else "" end);
    [ .rules[] | select(.switch == true) | . as $r
      | (if $r.outbound == "direct" then "DIRECT" else "PROXY" end) as $t
      | [ rtype | keys_unsorted[] | select(($r[.] // []) | length > 0) ] as $ks
      | if ($ks | length) == 0 then empty
        elif ($ks | length) == 1 or $r["or"] != false then
          $ks[] as $k | vals($r; $k)[] as $v | line($k; $v; $t)
        else
          "AND,(" + ([ $ks[] as $k | vals($r; $k) as $vs
            | if ($vs | length) == 1 then "(" + term($k; $vs[0]) + ")"
              else "(OR,(" + ([ $vs[] | "(" + term($k; .) + ")" ] | join(",")) + "))" end
          ] | join(",")) + ")," + $t
        end
    ]
  ' "$RULES_FILE"
}

# Domain patterns of direct groups made only of domain fields: resolved by the system DNS
# (corporate/split-DNS names that public DNS cannot answer) and kept out of fake-ip.
# keyword/regex conditions cannot be expressed as DNS patterns and are skipped.
compile_direct_domains() {
  seed_rules_file_if_missing
  run_root jq -c '
    def conds: ["domain","domain_suffix","domain_keyword","domain_regex","ip_cidr","port","port_range","process_name","package_name","network","protocol"];
    [ .rules[] | select(.switch == true and .outbound == "direct") | . as $r
      | [ conds[] | select(($r[.] // []) | length > 0) ] as $ks
      | select(($ks | length) > 0 and ($ks | all(. as $k | ["domain","domain_suffix","domain_keyword","domain_regex"] | index($k))))
      | ($r.domain // [])[], (($r.domain_suffix // [])[] | "+." + .)
    ] | unique
  ' "$RULES_FILE"
}

# build_mihomo_config — prints the config JSON from ST_* (state globals) and CTL_*.
build_mihomo_config() {
  local rules direct auto_route
  rules="$(compile_mihomo_rules)"
  direct="$(compile_direct_domains)"
  auto_route=false
  [[ "$ST_SCOPE" == "all" ]] && auto_route=true
  control_endpoint

  jq -n \
    --arg mode "$ST_MODE" --arg url "$ST_URL" --arg primary "$ST_PRIMARY" \
    --argjson proxy "$ST_PROXY" --argjson rules "$rules" --argjson direct "$direct" \
    --argjson auto_route "$auto_route" --argjson auto_redirect "${OS_AUTO_REDIRECT:-false}" \
    --arg tun_name "${OS_TUN_INTERFACE:-}" --argjson dashboard "$ST_DASH" \
    --arg ctl_bind "$CTL_BIND" --arg ctl_secret "$CTL_SECRET" --arg ui_dir "$CLASH_UI_DIR" \
    --arg probe "$PROBE_URL" --arg exclude "$SUB_EXCLUDE" --argjson refresh "$SUBSCRIPTION_REFRESH_SEC" '
    def esc: gsub("(?<c>[.^$|?*+()\\[\\]{}\\\\])"; "\\" + .c);
    def groups:
      if $mode == "subscription" then
        ([{name: "AUTO", type: "url-test", use: ["sub"], url: $probe, interval: 180, tolerance: 50}]
         + (if $primary != "" then
              # PRIMARY keeps REJECT as a member: with no node matching, an empty group would
              # turn into DIRECT and look alive to the fallback group.
              [{name: "PRIMARY", type: "url-test", proxies: ["REJECT"], use: ["sub"],
                filter: ("^" + ($primary | esc) + "$"), url: $probe, interval: 20},
               {name: "BACKUP", type: "url-test", use: ["sub"],
                "exclude-filter": ("^" + ($primary | esc) + "$|" + $exclude),
                url: $probe, interval: 30, tolerance: 50},
               {name: "FAILOVER", type: "fallback", proxies: ["PRIMARY", "BACKUP"], url: $probe, interval: 20}]
            else [] end)
         + [{name: "PROXY", type: "select", use: ["sub"],
             proxies: ((if $primary != "" then ["FAILOVER", "AUTO"] else ["AUTO"] end) + ["DIRECT"])}])
      else
        [{name: "PROXY", type: "select", proxies: ["SERVER", "DIRECT"]}]
      end;
    {
      mode: "rule", "log-level": "info", "allow-lan": false, ipv6: false, "unified-delay": true,
      "external-controller": $ctl_bind, secret: $ctl_secret,
      profile: {"store-selected": true},
      tun: ({enable: true, stack: "mixed", "auto-route": $auto_route, "auto-detect-interface": true,
             "strict-route": $auto_route, "dns-hijack": ["any:53"], mtu: 1500}
            + (if $tun_name != "" then {device: $tun_name} else {} end)
            + (if $auto_redirect and $auto_route then {"auto-redirect": true} else {} end)
            + (if $auto_route then {} else {"inet4-address": ["198.18.0.1/30"]} end)),
      dns: ({enable: true, ipv6: false, "enhanced-mode": "fake-ip",
             "default-nameserver": ["1.1.1.1", "8.8.8.8"],
             nameserver: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"],
             "proxy-server-nameserver": ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]}
            + (if ($direct | length) > 0 then
                 {"fake-ip-filter": $direct, "nameserver-policy": ($direct | map({(.): "system"}) | add)}
               else {} end)),
      "proxy-groups": groups,
      rules: ($rules + ["MATCH,PROXY"])
    }
    + (if $mode == "subscription" then
        {"proxy-providers": {sub: {type: "http", url: $url, path: "./providers/sub.yaml", interval: $refresh,
           "exclude-filter": $exclude,
           "health-check": {enable: true, url: $probe, interval: 60}}}}
       else {proxies: [$proxy]} end)
    + (if $dashboard then
        {"external-ui": $ui_dir,
         "external-ui-url": "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"}
       else {} end)
  '
}

# apply_config [restart] — stdin: config JSON. Validates with mihomo itself, keeps a backup
# of the previous file, installs the new one, then re-reads it in place through the API
# (no restart, so a refresh or a rules change does not cut connections); restarts the
# service when it is not running, the API call fails, or `restart` is passed.
apply_config() {
  local force="${1:-}" tmp errf backup
  tmp="$(mktemp)"; errf="$(mktemp)"
  cat > "$tmp"
  run_root install -d -m 0755 "$CONFIG_DIR"
  run_root install -d -m 0700 "$PROVIDERS_DIR"

  if ! run_root "$MIHOMO_BIN" -t -d "$CONFIG_DIR" -f "$tmp" >/dev/null 2>"$errf"; then
    grep -E 'level=(error|fatal)|error' "$errf" >&2 || cat "$errf" >&2
    rm -f "$tmp" "$errf"
    die "mihomo rejected the generated config"
  fi
  rm -f "$errf"

  if run_root test -f "$CONFIG_FILE"; then
    backup="${CONFIG_DIR}/config.backup-$(date +%Y%m%d-%H%M%S).yaml"
    run_root cp "$CONFIG_FILE" "$backup"
    # keep the five newest backups
    run_root sh -c "ls -1t '${CONFIG_DIR}'/config.backup-*.yaml 2>/dev/null | tail -n +6 | xargs rm -f"
  fi
  run_root install -m 0600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"

  if [[ "$force" != "restart" ]] && os_service_is_active \
     && api_call PUT "/configs?force=true" "$(jq -cn --arg p "$CONFIG_FILE" '{path: $p, payload: ""}')" >/dev/null 2>&1; then
    log "Config re-read by the running mihomo (no restart)"
    return 0
  fi
  os_service_restart
  sleep 2
}

# rebuild_and_apply [restart] — regenerate the config from the saved state and apply it.
rebuild_and_apply() {
  load_state
  [[ -n "$ST_MODE" ]] && run_root test -f "$STATE_FILE" || die "Configure the VPN first: $(basename "$0") configure or subscribe <url>"
  build_mihomo_config | apply_config "${1:-}"
}

# Names of the servers in a subscription as a JSON array (what the provider will expose),
# for the priority-server prompt. Same exclusion as the provider's exclude-filter.
subscription_names() {
  local text line name
  text="$(fetch_subscription_url "$1")"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" == *"#"* ]] || continue
    name="$(url_decode "${line#*#}")"
    [[ -n "$name" ]] || continue
    grep -qE "$SUB_EXCLUDE" <<<"$name" && continue
    printf '%s\n' "$name"
  done <<<"$text" | jq -R . | jq -s .
}

configure_vpn() {
  ensure_runtime_dependencies
  ensure_cmd jq curl "$MIHOMO_BIN"
  os_check_cmds

  local input_type uri json_payload mode outbound sub_url dashboard_enabled user_scope include_uids_json

  # One question at a time: choose a format, paste it right away, only then move on to
  # rules, users and the dashboard.
  input_type="$(select_input_type)"
  case "$input_type" in
    subscription)
      ensure_cmd base64
      sub_url="$(read_subscription_url)"
      ;;
    url)
      echo
      read -r -p "Paste VPN URL: " uri
      [[ "$(detect_uri_scheme "$uri")" != "unknown" ]] || die "Unsupported URI scheme. Expected vless:// or ss://"
      outbound="$(build_outbound_from_uri "$uri")"
      ;;
    *)
      mode="$(select_mode)"
      json_payload="$(read_json_payload)"
      outbound="$(build_outbound_from_json "$json_payload" "$mode")"
      ;;
  esac

  # Asked once here (never during the unattended refresh) for both paths.
  select_rules_source

  load_state
  if [[ "$input_type" == "subscription" ]]; then
    dashboard_enabled="$(select_dashboard_enabled)"
    [[ "$dashboard_enabled" == "true" ]] && CLASH_API_BIND="$(select_clash_api_bind)"
    log "Downloading subscription..."
    SUBSCRIPTION_TAGS_JSON="$(subscription_names "$sub_url")"
    [[ "$(jq 'length' <<<"$SUBSCRIPTION_TAGS_JSON")" -gt 0 ]] || die "Could not find any server in the subscription"
    SUB_PRIMARY="$ST_PRIMARY"
    select_primary_server
    ST_MODE="subscription"; ST_SCOPE="all"; ST_UIDS='[]'; ST_URL="$sub_url"
    ST_PRIMARY="$SUB_PRIMARY"; ST_PROXY="null"
  else
    user_scope="$(select_user_scope)"
    include_uids_json='[]'
    [[ "$user_scope" == "selected" ]] && include_uids_json="$(read_selected_user_uids)"
    dashboard_enabled="$(select_dashboard_enabled)"
    [[ "$dashboard_enabled" == "true" ]] && CLASH_API_BIND="$(select_clash_api_bind)"
    ST_MODE="single"; ST_SCOPE="$user_scope"; ST_UIDS="$include_uids_json"; ST_URL=""; ST_PRIMARY=""
    ST_PROXY="$(sb_outbound_to_mihomo <<<"$outbound")" || die "This server type cannot be converted for mihomo"
  fi
  ST_DASH="$dashboard_enabled"; ST_BIND="$CLASH_API_BIND"

  save_state
  os_service_write
  if [[ "$ST_SCOPE" == "selected" ]]; then
    clear_selected_routing
    clear_legacy_sing_box_routing
  else
    clear_selected_routing
    remove_custom_nft_files
  fi
  os_service_reload
  os_service_enable >/dev/null
  build_mihomo_config | apply_config restart
  report_result
}

report_result() {
  local current_ip
  os_service_is_active || die "mihomo failed to start. Run: $(basename "$0") logs"
  current_ip="$(detect_public_ip)"
  if [[ "$ST_MODE" == "subscription" ]]; then
    log "Subscription applied. mihomo refreshes it itself every ${SUBSCRIPTION_REFRESH_SEC}s."
  elif [[ "$ST_SCOPE" == "selected" ]]; then
    log "VPN config applied. Selected-users mode uses Linux nftables + ip rule by UID."
  else
    log "VPN config applied. All users mode is active."
  fi
  if [[ "$ST_DASH" == "true" ]]; then
    echo "[INFO] Dashboard: http://${ST_BIND}/ui/ (reachable only from ${ST_BIND%%:*})"
  else
    echo "[INFO] Dashboard is disabled. Enable it via: $(basename "$0") reconfigure"
  fi
  if [[ -n "$current_ip" ]]; then
    echo "[INFO] Your current public IP: $current_ip"
  else
    echo "[INFO] Could not detect public IP automatically."
  fi
}

# ---------------------------------------------------------------------------
# Subscription helpers
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
    warn "process_name/port rules only match traffic that originates on this box itself (mihomo runs on the router, not on client devices) — domain/ip_cidr rules still work normally for hotspot clients."
  else
    log "Created empty rules file: $RULES_FILE (add groups with: $(basename "$0") rules edit, or set VPNC_RULES_SEED_PATH/VPNC_RULES_SEED_URL before first use)"
  fi
}

# `vpnc subscribe [url]` — without a URL: ask mihomo to refresh the saved subscription now
# (it also does it on its own every SUBSCRIPTION_REFRESH_SEC). With a URL: switch to it,
# reusing the saved dashboard choice (asked once when there is no saved state).
subscribe_vpn() {
  ensure_runtime_dependencies
  ensure_cmd jq curl "$MIHOMO_BIN"
  os_check_cmds

  local url="${1:-}" dashboard_enabled
  load_state

  if [[ -z "$url" ]]; then
    [[ "$ST_MODE" == "subscription" && -n "$ST_URL" ]] \
      || die "No saved subscription. Usage: $(basename "$0") subscribe <url>"
    api_call PUT /providers/proxies/sub >/dev/null \
      || die "Could not reach mihomo's API; is the service running? ($(basename "$0") status)"
    log "Subscription refresh requested (servers are replaced in place, connections stay)"
    return 0
  fi

  if run_root test -f "$STATE_FILE"; then
    [[ "$ST_URL" == "$url" ]] || ST_PRIMARY=""
  else
    dashboard_enabled="$(select_dashboard_enabled)"
    ST_DASH="$dashboard_enabled"
    [[ "$dashboard_enabled" == "true" ]] && ST_BIND="$(select_clash_api_bind)"
  fi
  ST_MODE="subscription"; ST_SCOPE="all"; ST_UIDS='[]'; ST_URL="$url"; ST_PROXY="null"

  save_state
  os_service_write
  clear_selected_routing
  clear_legacy_sing_box_routing
  remove_custom_nft_files
  os_service_reload
  os_service_enable >/dev/null
  build_mihomo_config | apply_config
  report_result
}

# `vpnc primary [name|number|off]` — show / set / clear the priority server (advanced).
# mihomo's fallback group does the rest: stays on it, drops to the backup group when it
# stops answering, returns as soon as it answers again.
cmd_primary() {
  local arg="${1:-}" names n=0 name target=""
  ensure_cmd jq curl
  load_state
  [[ "$ST_MODE" == "subscription" && -n "$ST_URL" ]] \
    || die "Priority server needs a subscription: $(basename "$0") subscribe <url>"

  if [[ -z "$arg" ]]; then
    names="$(subscription_names "$ST_URL")"
    echo "Priority server: ${ST_PRIMARY:-(none)}"
    while IFS= read -r name; do
      n=$((n + 1))
      printf '  %2d) %s%s\n' "$n" "$name" "$([[ "$name" == "$ST_PRIMARY" ]] && echo '  <- priority')"
    done < <(jq -r '.[]' <<<"$names")
    echo "Set: $(basename "$0") primary <name|number>   Clear: $(basename "$0") primary off"
    return
  fi

  if [[ "$arg" != "off" ]]; then
    names="$(subscription_names "$ST_URL")"
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
      target="$(jq -r --argjson i "$arg" '.[$i - 1] // empty' <<<"$names")"
      [[ -n "$target" ]] || die "No server number $arg"
    else
      jq -e --arg a "$arg" 'index($a)' <<<"$names" >/dev/null || die "No such server: $arg (list: $(basename "$0") primary)"
      target="$arg"
    fi
  fi

  ST_PRIMARY="$target"
  save_state
  build_mihomo_config | apply_config
  if [[ -n "$target" ]]; then log "Priority server: $target"; else log "Priority server cleared"; fi
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
  rebuild_and_apply
  log "Rules applied"
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
  local current_ip users
  current_ip="$(detect_public_ip)"
  load_state

  echo
  echo "VPN summary:"
  if [[ -n "$current_ip" ]]; then
    echo "  Public IP: $current_ip"
  else
    echo "  Public IP: unavailable"
  fi
  if ! run_root test -f "$STATE_FILE"; then
    echo "  Mode: not configured ($(basename "$0") configure)"
    return
  fi
  echo "  Engine: mihomo"
  if [[ "$ST_MODE" == "subscription" ]]; then
    echo "  Mode: subscription (refreshed by mihomo every ${SUBSCRIPTION_REFRESH_SEC}s)"
    echo "  Subscription URL: $ST_URL"
    echo "  Priority server: ${ST_PRIMARY:-none} (set: $(basename "$0") primary)"
    show_api_summary
  else
    echo "  Mode: $ST_SCOPE"
    users="$(jq -r 'map(tostring) | join(", ")' <<<"$ST_UIDS")"
    [[ -z "$users" ]] || echo "  Routed UIDs: $users"
  fi
  if [[ "$ST_DASH" == "true" ]]; then
    echo "  Dashboard: http://${ST_BIND}/ui/"
  else
    echo "  Dashboard: disabled (enable via: $(basename "$0") reconfigure)"
  fi
}

# Live view from mihomo's API: servers in the pool and what the groups point at now.
show_api_summary() {
  local g now
  api_call GET /providers/proxies/sub >/dev/null 2>&1 || { echo "  mihomo API: unreachable"; return; }
  echo "  Servers: $(api_call GET /providers/proxies/sub | jq '.proxies | length')"
  for g in PROXY FAILOVER PRIMARY BACKUP AUTO; do
    now="$(api_call GET "/proxies/${g}" 2>/dev/null | jq -r '.now // empty' 2>/dev/null)" || continue
    [[ -z "$now" ]] || echo "  ${g} -> ${now}"
  done
}

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat <<HELP_EOF
Usage: ${cmd} <command>

Engine: mihomo (Clash.Meta). Config: $CONFIG_FILE.

Commands:
  configure          Interactive setup: single server (vless:// / ss:// / JSON) or a
                     subscription (multiple servers). Also asks about the direct-vs-VPN
                     rules file (skip / a well-known local path / a URL / a file path),
                     an optional priority server (subscription) and whether to enable
                     the web dashboard.
  reconfigure        Same as configure
  subscribe [url]    With a URL: switch to that subscription (reuses the saved dashboard
                     choice). Without: refresh the saved subscription right now.
  primary [name|n|off]  Advanced: priority server for a subscription. Shows the list
                     without arguments. See "Priority server" below.
  rules edit         Edit the direct-vs-VPN rules file (\$EDITOR, default nano)
  rules import <path|url>   Replace the rules file from a {"rules": [...]} JSON
  rules list         Show rule groups and their on/off state
  rules toggle <name> on|off   Flip a rule group without opening the editor
  rules apply        Recompile rules into the mihomo config and re-read it (no restart)
  status             Show service status
  start              Start VPN service
  stop               Stop VPN service
  restart            Restart VPN service
  enable             Enable autostart on boot
  disable            Disable autostart on boot
  uninstall          Completely remove mihomo and all configurations
  logs               Follow mihomo logs
  show-config        Print $CONFIG_FILE
  show-state         Print $STATE_FILE
  help               Show this help

Web dashboard:
  metacubexd (server list, ping, manual pick) is off by default and only turns on if you
  answer "yes" to "Enable web dashboard?" during configure/subscribe; you are then asked
  for the bind address (IP:port), VPNC_CLASH_API_BIND / the built-in default is offered.
  It is local and has no secret. Once enabled: http://<bind>/ui/.

Direct-vs-VPN rules:
  \$RULES_FILE ($RULES_FILE) starts out empty unless seeded. To seed it from a JSON file,
  set VPNC_RULES_SEED_PATH=<local path> or VPNC_RULES_SEED_URL=<url> (format:
  {"rules": [...]}) before the first "rules" command runs.

Subscription:
  mihomo downloads the subscription itself (proxy-providers) every
  ${SUBSCRIPTION_REFRESH_SEC}s (VPNC_SUBSCRIPTION_REFRESH_SEC before configure/subscribe),
  health-checks every server and updates their definitions in place; there is no
  vpnc timer and nothing restarts. Torrent/whitelist-CDN nodes are filtered out.

Priority server (advanced, subscription mode):
  "${cmd} primary <name|number>" pins one server. A fallback group keeps traffic on it, moves
  to the fastest other server when it stops answering and returns as soon as it answers
  again. If the server disappears from the subscription, traffic goes to the others.
  "primary off" clears it.
HELP_EOF
}

uninstall_vpn() {
  ensure_runtime_dependencies
  echo "[WARN] This will completely remove mihomo and all its configurations!"
  echo "[WARN] The following will be deleted:"
  echo "  - $MIHOMO_BIN"
  echo "  - /etc/mihomo/"
  echo "  - $(os_service_file)"
  echo "  - /usr/local/bin/vpnc"
  echo "  - /usr/local/bin/makrelbka-vpnc"
  echo "  - /usr/local/lib/vpnc/"
  echo
  read -r -p "Are you absolutely sure? Type 'yes' to continue: " confirmation

  if [[ "$confirmation" != "yes" ]]; then
    echo "Uninstall cancelled."
    return
  fi

  echo "Stopping and disabling mihomo service..."
  os_service_stop 2>/dev/null || true
  os_service_disable 2>/dev/null || true

  echo "Clearing routing runtime rules..."
  clear_selected_routing
  clear_legacy_sing_box_routing

  echo "Removing service file..."
  os_service_remove
  os_service_reload

  echo "Removing mihomo binary..."
  run_root rm -f "$MIHOMO_BIN"

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
  run_root rm -rf /etc/mihomo

  echo "Removing manager script..."
  run_root rm -f /usr/local/bin/vpnc /usr/local/bin/makrelbka-vpnc
  run_root rm -rf /usr/local/lib/vpnc

  echo "[SUCCESS] mihomo has been completely uninstalled."
  echo "You may want to reboot your system to clean up any remaining TUN interfaces."
}
