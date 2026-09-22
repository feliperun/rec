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
INSTALL_DIR="${INSTALL_DIR%/}"
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

release_json="$(curl -fsSL "$release_url")"

# Emit exactly the browser_download_url whose path ends in /<name>, so the
# <asset> lookup cannot also match its <asset>.sha256 sibling.
extract_url() {
  printf '%s\n' "$release_json" \
    | grep -o "\"browser_download_url\": *\"[^\"]*/${1}\"" \
    | sed -E 's/.*"(https:[^"]+)"/\1/'
}

download_url="$(extract_url "$asset")"
checksum_url="$(extract_url "${asset}.sha256")"

if [ -z "$download_url" ]; then
  echo "error: could not find a '${asset}' asset in ${release_url}" >&2
  exit 1
fi

if [ -z "$checksum_url" ]; then
  echo "error: could not find a '${asset}.sha256' checksum in ${release_url}" >&2
  exit 1
fi

# The JSON comes from api.github.com over TLS, but only trust a release
# download under this repository; anything else is refused before fetching.
for url in "$download_url" "$checksum_url"; do
  case "$url" in
    "https://github.com/${REPO}/releases/download/"*) ;;
    *)
      echo "error: refusing to download from unexpected URL: ${url}" >&2
      exit 1
      ;;
  esac
done

tmp_bin="$(mktemp)"
tmp_sum="$(mktemp)"
trap 'rm -f "$tmp_bin" "$tmp_sum"' EXIT

echo "Downloading ${download_url}..."
curl -fsSL -o "$tmp_bin" "$download_url"
curl -fsSL -o "$tmp_sum" "$checksum_url"

checksum_line="$(head -n 1 "$tmp_sum")"
expected_sum="$(printf '%s\n' "$checksum_line" | awk '{print $1}')"
checksum_name="$(printf '%s\n' "$checksum_line" | awk '{print $2}')"

if ! printf '%s' "$expected_sum" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "error: malformed checksum for ${asset}: ${checksum_line}" >&2
  exit 1
fi

if [ "$checksum_name" != "$asset" ]; then
  echo "error: checksum names '${checksum_name}', expected '${asset}'" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_sum="$(sha256sum "$tmp_bin" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual_sum="$(shasum -a 256 "$tmp_bin" | awk '{print $1}')"
else
  echo "error: neither sha256sum nor shasum is available to verify the download" >&2
  exit 1
fi

if [ "$actual_sum" != "$expected_sum" ]; then
  echo "error: checksum mismatch for ${asset}" >&2
  echo "  expected: ${expected_sum}" >&2
  echo "  actual:   ${actual_sum}" >&2
  exit 1
fi
echo "Verified ${asset} checksum."

# mktemp creates the file 0600 and `chmod +x` honours the umask, which leaves
# the install at 0711: every user but the installing one loses read access to
# a binary whose whole point is to sit on a shared PATH.
chmod 755 "$tmp_bin"

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

# The shell runs the first ${BIN_NAME} on PATH, not the newest one on disk, so
# an older copy ahead of ${INSTALL_DIR} keeps answering and the install reads
# as if it did nothing.
found="$(command -v "$BIN_NAME" 2>/dev/null || true)"
if [ -z "$found" ]; then
  echo "note: ${INSTALL_DIR} is not on your PATH; add it to run ${BIN_NAME} by name" >&2
elif [ "$found" != "$dest" ]; then
  echo "warning: ${found} is earlier on your PATH and runs instead of ${dest}" >&2
  echo "         remove it, or put ${INSTALL_DIR} ahead of it" >&2
fi

"$dest" --help || true
