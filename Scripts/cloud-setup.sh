#!/usr/bin/env bash
# Setup script for Claude Code cloud sessions (Ubuntu 24.04, x86_64 or aarch64).
# Installs what PeoplemapsCore and the Python importer need on Linux:
#   - a pinned Swift toolchain from swift.org, in /opt/swift
#   - libsqlite3-dev, zlib1g-dev, python3
# Safe to run more than once: each step checks before it does anything.
set -euo pipefail

SWIFT_VERSION="${PEOPLEMAPS_SWIFT_VERSION:-6.4.2}"
SWIFT_ROOT="${PEOPLEMAPS_SWIFT_ROOT:-/opt/swift}"

log() { printf '[cloud-setup] %s\n' "$*"; }

if [[ $(id -u) -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

# --- apt packages ------------------------------------------------------------
# Swift's own runtime needs (binutils, libc6-dev, libstdc++-13-dev, ...) are
# usually already in the image; only missing ones are installed.
apt_packages=(
  python3 libsqlite3-dev zlib1g-dev
  ca-certificates curl gnupg tar
  binutils libc6-dev libgcc-13-dev libstdc++-13-dev libedit2 libncurses-dev
  libpython3-dev libsqlite3-0 pkg-config tzdata git
)
missing=()
for pkg in "${apt_packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    missing+=("$pkg")
  fi
done
if ((${#missing[@]})); then
  log "installing apt packages: ${missing[*]}"
  "${SUDO[@]}" apt-get update -qq
  DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y -qq --no-install-recommends "${missing[@]}"
else
  log "apt packages already installed"
fi

# --- Swift toolchain ---------------------------------------------------------
# shellcheck source=/dev/null
. /etc/os-release
case "${ID}-${VERSION_ID}" in
  ubuntu-24.04) platform=ubuntu2404; platform_name=ubuntu24.04 ;;
  ubuntu-22.04) platform=ubuntu2204; platform_name=ubuntu22.04 ;;
  *) log "unsupported OS ${ID} ${VERSION_ID}"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64) arch_suffix="" ;;
  aarch64 | arm64) arch_suffix="-aarch64"; platform="${platform}-aarch64" ;;
  *) log "unsupported architecture $(uname -m)"; exit 1 ;;
esac

tag="swift-${SWIFT_VERSION}-RELEASE"
name="${tag}-${platform_name}${arch_suffix}"
install_dir="${SWIFT_ROOT}/${name}"

if [[ -x "${install_dir}/usr/bin/swift" ]]; then
  log "Swift ${SWIFT_VERSION} already installed at ${install_dir}"
else
  url="https://download.swift.org/swift-${SWIFT_VERSION}-release/${platform}/${tag}/${name}.tar.gz"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  log "downloading ${url}"
  curl -fsSL --retry 4 -o "${work}/swift.tar.gz" "$url"
  curl -fsSL --retry 4 -o "${work}/swift.tar.gz.sig" "${url}.sig"
  curl -fsSL --retry 4 -o "${work}/keys.asc" https://www.swift.org/keys/all-keys.asc
  export GNUPGHOME="${work}/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --import "${work}/keys.asc"
  gpg --batch --quiet --verify "${work}/swift.tar.gz.sig" "${work}/swift.tar.gz"
  log "signature verified; extracting to ${install_dir}"
  "${SUDO[@]}" mkdir -p "${install_dir}.partial"
  "${SUDO[@]}" tar -xzf "${work}/swift.tar.gz" -C "${install_dir}.partial" --strip-components=1
  "${SUDO[@]}" rm -rf "$install_dir"
  "${SUDO[@]}" mv "${install_dir}.partial" "$install_dir"
  unset GNUPGHOME
fi
"${SUDO[@]}" ln -sfn "$install_dir" "${SWIFT_ROOT}/current"

# --- PATH ---------------------------------------------------------------------
# Login shells read /etc/profile.d; non-login bash shells read ~/.bashrc.
path_line="export PATH=\"${SWIFT_ROOT}/current/usr/bin:\$PATH\""
profile_file=/etc/profile.d/peoplemaps-swift.sh
if [[ "$(cat "$profile_file" 2>/dev/null)" != "$path_line" ]]; then
  printf '%s\n' "$path_line" | "${SUDO[@]}" tee "$profile_file" >/dev/null
  log "wrote ${profile_file}"
fi
if ! grep -qxF "$path_line" "${HOME}/.bashrc" 2>/dev/null; then
  printf '%s\n' "$path_line" >>"${HOME}/.bashrc"
  log "added Swift to PATH in ~/.bashrc"
fi
export PATH="${SWIFT_ROOT}/current/usr/bin:${PATH}"

log "$(swift --version 2>&1 | head -1)"
log "$(python3 --version)"
log "done"
