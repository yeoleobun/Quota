#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_NAME="Quota"
EXEC_TARGET="QuotaBar"
VERSION="${VERSION:-0.1.0}"
BUNDLE_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
ZIP_PATH="${ROOT_DIR}/dist/${APP_NAME}-macos-arm64.zip"
DMG_PATH="${ROOT_DIR}/dist/${APP_NAME}-macos-arm64.dmg"

cd "${ROOT_DIR}"

echo "==> Building ${APP_NAME} ${VERSION} (release, arm64)..."
swift build -c release --arch arm64

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/${EXEC_TARGET}"

echo "==> Packaging ${BUNDLE_DIR}..."
rm -rf "${BUNDLE_DIR}" "${ROOT_DIR}/dist/QuotaBar.app" "${ZIP_PATH}" "${DMG_PATH}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

if [[ -f "${ROOT_DIR}/Assets/AppIcon.icns" ]]; then
    cp "${ROOT_DIR}/Assets/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
fi

cat > "${BUNDLE_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.quota.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

SIGN_IDENTITY="${SIGN_IDENTITY:-yeoleobun}"
if ! security find-identity -p codesigning | grep -Fq "\"${SIGN_IDENTITY}\""; then
    echo "Error: Signing identity \"${SIGN_IDENTITY}\" not found in keychain." >&2
    exit 1
fi
echo "==> Signing ${BUNDLE_DIR} with identity \"${SIGN_IDENTITY}\"..."
codesign --force --deep --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"

echo "==> Creating ${ZIP_PATH}..."
ditto -c -k --sequesterRsrc --keepParent "${BUNDLE_DIR}" "${ZIP_PATH}"

if [[ "${PACKAGE_DMG:-0}" == "1" ]]; then
    echo "==> Creating ${DMG_PATH}..."
    STAGING_DIR="$(mktemp -d)"
    cp -R "${BUNDLE_DIR}" "${STAGING_DIR}/${APP_NAME}.app"
    ln -s /Applications "${STAGING_DIR}/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}" >/dev/null
    rm -rf "${STAGING_DIR}"
fi

echo "==> Done! App bundle created at:"
echo "    ${BUNDLE_DIR}"
echo "    ${ZIP_PATH}"
