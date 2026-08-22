#!/bin/sh
# Installs the latest release of rec (https://github.com/feliperun/rec) to
# /usr/local/bin. Usage:
#
#   curl -fsSL https://raw.githubusercontent.com/feliperun/rec/main/install.sh | sh
#
set -eu

REPO="feliperun/rec"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BIN_NAME="rec"

os="$(uname -s)"
if [ "$os" != "Darwin" ]; then
  echo "error: $BIN_NAME only ships macOS builds (detected: $os)" >&2
  exit 1
fi

arch="$(uname -m)"
if [ "$arch" != "arm64" ]; then
  echo "error: $BIN_NAME only ships Apple Silicon (arm64) builds (detected: $arch)" >&2
  exit 1
fi
asset="rec-macos-arm64"

api_url="https://api.github.com/repos/${REPO}/releases/latest"
download_url="$(curl -fsSL "$api_url" | grep -o "\"browser_download_url\": *\"[^\"]*${asset}\"" | sed -E 's/.*"(https:[^"]+)"/\1/')"

if [ -z "$download_url" ]; then
  echo "error: could not find a '${asset}' asset in the latest release of ${REPO}" >&2
  exit 1
fi

tmp_bin="$(mktemp)"
trap 'rm -f "$tmp_bin"' EXIT

echo "Downloading ${download_url}..."
curl -fsSL -o "$tmp_bin" "$download_url"
chmod +x "$tmp_bin"

if [ ! -d "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR"
fi

dest="${INSTALL_DIR}/${BIN_NAME}"
if [ -w "$INSTALL_DIR" ]; then
  mv "$tmp_bin" "$dest"
else
  sudo mv "$tmp_bin" "$dest"
fi

echo "Installed ${BIN_NAME} to ${dest}"
"$dest" --help || true
