#!/usr/bin/env bash
# vpnc installer (Linux, macOS).
#
# Layout:
#   lib/common.sh   shared logic (config generation, parsers, rules)
#   lib/linux.sh    Linux layer  (apt/dnf/..., systemd, nftables)
#   lib/macos.sh    macOS layer  (brew, launchd)
#   bin/vpnc        manager entry point
#
# Works both from a checkout (./install.sh) and piped from curl; in the latter case
# the files above are downloaded from $VPNC_RAW_BASE (VPNC_REF selects branch/tag).
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SKIP_BOOTSTRAP=0
if [[ $# -gt 0 ]] && [[ "$1" != "install" ]] && [[ "$1" != "--no-configure" ]]; then
  SKIP_BOOTSTRAP=1
fi

MANAGER_PATH="/usr/local/bin/vpnc"
LEGACY_MANAGER_PATH="/usr/local/bin/makrelbka-vpnc"
LIB_INSTALL_DIR="/usr/local/lib/vpnc"

VPNC_REF="${VPNC_REF:-main}"
VPNC_RAW_BASE="${VPNC_RAW_BASE:-https://raw.githubusercontent.com/makrelbka/makrelbka-vpnc/${VPNC_REF}}"
VPNC_FILES=(lib/common.sh lib/linux.sh lib/macos.sh bin/vpnc)

SRC_DIR=""
TMP_SRC=""

# Minimal helpers until lib/common.sh (which redefines them) is sourced.
log() {
  echo "[INFO] $*"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

cleanup() {
  [[ -n "$TMP_SRC" ]] && rm -rf "$TMP_SRC"
  return 0
}
trap cleanup EXIT

# Uses the checkout next to this script if there is one, otherwise downloads the files.
stage_sources() {
  local self dir f
  self="${BASH_SOURCE[0]:-$0}"
  dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd || true)"

  if [[ -n "$dir" && -f "$dir/lib/common.sh" && -f "$dir/bin/vpnc" ]]; then
    SRC_DIR="$dir"
    return
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required to download installer files"

  TMP_SRC="$(mktemp -d)"
  mkdir -p "$TMP_SRC/lib" "$TMP_SRC/bin"
  for f in "${VPNC_FILES[@]}"; do
    log "Downloading $f"
    curl -fsSL "${VPNC_RAW_BASE}/${f}" -o "$TMP_SRC/$f" \
      || die "Could not download ${VPNC_RAW_BASE}/${f}"
  done
  SRC_DIR="$TMP_SRC"
}

ensure_sudo() {
  if [[ -n "$SUDO" ]]; then
    if ! "$SUDO" -n true 2>/dev/null; then
      log "Checking sudo privileges (you may be prompted for password)..."
      "$SUDO" true
    fi
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
  log "Detected platform: ${OS_NAME_RELEASE}-${arch}"

  target_version="${SING_BOX_VERSION:-1.12.20}"

  if [[ "$target_version" == "latest" ]]; then
    release_json="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest)" \
      || die "Could not query the GitHub API (rate limit?). Set SING_BOX_VERSION to a fixed version instead."
    tag="$(jq -r '.tag_name' <<<"$release_json")"
    version="${tag#v}"

    asset_url="$(jq -r --arg v "$version" --arg os "$OS_NAME_RELEASE" --arg arch "$arch" '
      .assets[]
      | select(.name == ("sing-box-" + $v + "-" + $os + "-" + $arch + ".tar.gz"))
      | .browser_download_url
    ' <<<"$release_json" | head -n1)"

    if [[ -z "$asset_url" ]]; then
      asset_url="$(jq -r --arg os "$OS_NAME_RELEASE" --arg arch "$arch" '
        .assets[]
        | select(.name | test($os + "-" + $arch + "\\.tar\\.gz$"))
        | .browser_download_url
      ' <<<"$release_json" | head -n1)"
    fi
  else
    # A pinned version needs no API call (the unauthenticated API is limited to
    # 60 requests/hour per IP); the release asset URL is predictable.
    tag="v${target_version}"
    version="${target_version}"
    asset_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-${OS_NAME_RELEASE}-${arch}.tar.gz"
  fi

  [[ -n "$asset_url" ]] || die "Could not find release asset for ${OS_NAME_RELEASE}-${arch}"

  tmp_dir="$(mktemp -d)"

  log "Downloading sing-box $tag"
  curl -fsSL "$asset_url" -o "$tmp_dir/sing-box.tar.gz" \
    || die "Could not download $asset_url (check SING_BOX_VERSION and your connection)"

  tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir"
  bin_path="$(find "$tmp_dir" -type f -name sing-box | head -n1)"
  [[ -n "$bin_path" ]] || die "sing-box binary was not found in archive"

  run_root install -d -m 0755 /usr/local/bin
  run_root install -m 0755 "$bin_path" /usr/local/bin/sing-box

  rm -rf "$tmp_dir"
  log "Installed sing-box to /usr/local/bin/sing-box"
}

install_manager() {
  local f

  run_root install -d -m 0755 /usr/local/bin "$LIB_INSTALL_DIR"

  for f in common.sh linux.sh macos.sh; do
    run_root install -m 0644 "$SRC_DIR/lib/$f" "$LIB_INSTALL_DIR/$f"
  done

  run_root install -m 0755 "$SRC_DIR/bin/vpnc" "$MANAGER_PATH"
  run_root ln -sf "$MANAGER_PATH" "$LEGACY_MANAGER_PATH"

  log "Installed manager commands: $MANAGER_PATH and $LEGACY_MANAGER_PATH (libs in $LIB_INSTALL_DIR)"
}

bootstrap() {
  local no_configure="0"
  if [[ "${1:-}" == "--no-configure" ]]; then
    no_configure="1"
  fi

  stage_sources

  # shellcheck source=lib/common.sh
  source "$SRC_DIR/lib/common.sh"
  VPNC_OS="$(detect_os)"
  # shellcheck source=lib/linux.sh
  source "$SRC_DIR/lib/${VPNC_OS}.sh"

  log "Detected OS: $VPNC_OS"

  ensure_sudo
  os_ensure_deps
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

if [[ $SKIP_BOOTSTRAP -eq 1 ]]; then
  if [[ -f "$MANAGER_PATH" ]]; then
    "$MANAGER_PATH" "$@"
  elif [[ -f "$LEGACY_MANAGER_PATH" ]]; then
    "$LEGACY_MANAGER_PATH" "$@"
  else
    echo "[ERROR] Manager not found at $MANAGER_PATH or $LEGACY_MANAGER_PATH" >&2
    exit 1
  fi
else
  bootstrap "$@"
fi
