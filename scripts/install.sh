#!/bin/zsh
set -euo pipefail

REPO="yeoleobun/Quota"
ASSET="Quota-macos-arm64.zip"
INSTALL_DIR="/Applications"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Error: Quota requires macOS on Apple Silicon (arm64)." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Downloading latest ${ASSET} from ${REPO}..."
curl -fsSL "https://github.com/${REPO}/releases/latest/download/${ASSET}" -o "${TMP_DIR}/${ASSET}"

echo "==> Extracting Quota.app..."
ditto -x -k "${TMP_DIR}/${ASSET}" "${TMP_DIR}"

pkill -x Quota 2>/dev/null || true
rm -rf "${INSTALL_DIR}/Quota.app"
mv "${TMP_DIR}/Quota.app" "${INSTALL_DIR}/Quota.app"
xattr -cr "${INSTALL_DIR}/Quota.app"

echo "==> Installed to ${INSTALL_DIR}/Quota.app! Launching Quota..."
open "${INSTALL_DIR}/Quota.app"
