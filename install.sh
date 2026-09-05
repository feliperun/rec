#!/bin/sh
# Installs a release of rec (https://github.com/feliperun/rec) to /usr/local/bin,
# picking the build for the running OS and architecture. Usage:
#
#   curl -fsSL https://raw.githubusercontent.com/feliperun/rec/main/install.sh | sh
#
# Overrides: VERSION=<tag> installs that release instead of the latest;
# INSTALL_DIR=<dir> installs there instead of /usr/local/bin.
# On Windows use install.ps1 (irm https://... /install.ps1 | iex).
set -eu

REPO="feliperun/rec"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BIN_NAME="rec"
VERSION="${VERSION:-}"

case "$(uname -s) $(uname -m)" in
  "Darwin arm64" | "Darwin aarch64") asset="rec-macos-arm64" ;;
  "Darwin x86_64") asset="rec-macos-intel" ;;
  "Linux x86_64") asset="rec-linux-x64" ;;
  "Linux aarch64" | "Linux arm64") asset="rec-linux-arm64" ;;
  *)
    echo "error: no ${BIN_NAME} build for $(uname -s) ($(uname -m))" >&2
    echo "on Windows use: irm https://raw.githubusercontent.com/${REPO}/main/install.ps1 | iex" >&2
    exit 1
    ;;
esac

release_url="https://api.github.com/repos/${REPO}/releases/latest"
if [ -n "$VERSION" ]; then
  release_url="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
fi

download_url="$(curl -fsSL "$release_url" | grep -o "\"browser_download_url\": *\"[^\"]*${asset}\"" | sed -E 's/.*"(https:[^"]+)"/\1/')"

if [ -z "$download_url" ]; then
  echo "error: could not find a '${asset}' asset in ${release_url}" >&2
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
