#!/usr/bin/env bash
# Build a menu-bar-only .app using the Xcode toolchain (Xcode-beta if needed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="GrokBar"
EXEC_NAME="GrokBar"
BUILD_DIR="${ROOT}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

# Prefer full Xcode (needed for SwiftUI + AppKit linking on recent macOS).
if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

SWIFTC="${DEVELOPER_DIR:-}/usr/bin/swiftc"
if [[ ! -x "$SWIFTC" ]]; then
  SWIFTC="$(command -v swiftc)"
fi

echo "Using: $SWIFTC"
"$SWIFTC" --version | head -1

mkdir -p "$MACOS_DIR" "$RES_DIR"

SOURCES=(
  "$ROOT/Sources/Models.swift"
  "$ROOT/Sources/AuthStore.swift"
  "$ROOT/Sources/UsageFetcher.swift"
  "$ROOT/Sources/UsageCache.swift"
  "$ROOT/Sources/StatusFetcher.swift"
  "$ROOT/Sources/LoginItemService.swift"
  "$ROOT/Sources/ProviderIcons.swift"
  "$ROOT/Sources/MenuBarRenderer.swift"
  "$ROOT/Sources/UsageViewModel.swift"
  "$ROOT/Sources/MenuContentView.swift"
  "$ROOT/Sources/StatusBarController.swift"
  "$ROOT/Sources/GrokBarApp.swift"
)

echo "Compiling ${#SOURCES[@]} sources…"
"$SWIFTC" \
  -parse-as-library \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "${SOURCES[@]}" \
  -o "${MACOS_DIR}/${EXEC_NAME}"

cp "$ROOT/Resources/Info.plist" "${CONTENTS}/Info.plist"
# Menu bar template mark: GrokBotIcon.svg (GrokIcon* kept as the fallback mark)
# App icon: AppIcon.icns (Dock / Finder) + AppIcon.png fallback
for icon in GrokIcon.png "GrokIcon@2x.png" "GrokIcon@3x.png" GrokIcon.svg \
            GrokBotIcon.svg CursorIcon.svg CursorIcon.png AppIcon.png AppIcon.icns; do
  if [[ -f "$ROOT/Resources/$icon" ]]; then
    cp "$ROOT/Resources/$icon" "${RES_DIR}/$icon"
  fi
done

# PkgInfo
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# ad-hoc sign so Gatekeeper is less angry for local runs
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo ""
echo "Built: ${APP_DIR}"
echo "Run:   open \"${APP_DIR}\""
echo "Install: cp -R \"${APP_DIR}\" /Applications/"
