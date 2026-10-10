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
# Optional: default routing rules seed. Missing/failed download is not fatal —
# install_manager() just skips seeding a default and rules start out empty.
VPNC_OPTIONAL_FILES=(vpnc-rules.local.json)

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
  for f in "${VPNC_OPTIONAL_FILES[@]}"; do
    curl -fsSL "${VPNC_RAW_BASE}/${f}" -o "$TMP_SRC/$f" 2>/dev/null \
      || { log "Optional file $f not available, skipping default rules seed"; rm -f "$TMP_SRC/$f"; }
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

# mihomo ships one gzipped binary per platform: mihomo-<os>-<arch>-v<version>.gz.
# A pinned version needs no GitHub API call (60 requests/hour per IP without a token).
install_mihomo() {
  local arch version tag asset_url tmp_dir

  arch="$(detect_arch)"
  case "$arch" in
    amd64|arm64|armv7) ;;
    *) die "No mihomo build for architecture: $arch" ;;
  esac
  log "Detected platform: ${OS_NAME_RELEASE}-${arch}"

  version="${MIHOMO_VERSION:-1.19.31}"
  if [[ "$version" == "latest" ]]; then
    tag="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | jq -r '.tag_name')" \
      || die "Could not query the GitHub API (rate limit?). Set MIHOMO_VERSION to a fixed version instead."
  else
    tag="v${version}"
  fi
  asset_url="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/mihomo-${OS_NAME_RELEASE}-${arch}-${tag}.gz"

  tmp_dir="$(mktemp -d)"
  log "Downloading mihomo $tag"
  curl -fsSL "$asset_url" -o "$tmp_dir/mihomo.gz" \
    || die "Could not download $asset_url (check MIHOMO_VERSION and your connection)"
  gunzip -f "$tmp_dir/mihomo.gz"

  run_root install -d -m 0755 /usr/local/bin
  run_root install -m 0755 "$tmp_dir/mihomo" /usr/local/bin/mihomo
  rm -rf "$tmp_dir"
  log "Installed mihomo to /usr/local/bin/mihomo"
}

install_manager() {
  local f

  run_root install -d -m 0755 /usr/local/bin "$LIB_INSTALL_DIR"

  for f in common.sh linux.sh macos.sh; do
    run_root install -m 0644 "$SRC_DIR/lib/$f" "$LIB_INSTALL_DIR/$f"
  done

  run_root install -m 0755 "$SRC_DIR/bin/vpnc" "$MANAGER_PATH"
  run_root ln -sf "$MANAGER_PATH" "$LEGACY_MANAGER_PATH"

  if [[ -f "$SRC_DIR/vpnc-rules.local.json" ]]; then
    run_root install -m 0644 "$SRC_DIR/vpnc-rules.local.json" "$LIB_INSTALL_DIR/vpnc-rules.default.json"
    log "Installed default routing rules seed to $LIB_INSTALL_DIR/vpnc-rules.default.json"
  fi

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
  install_mihomo
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
