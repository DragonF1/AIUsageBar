#!/bin/bash
# Builds AIUsageBar.app into dist/. Pass --install to copy it to /Applications.
# Signs with $CODESIGN_IDENTITY, else with "AI Usage Bar Dev" when scripts/make-signing-identity.sh
# has created it (keeps macOS privacy grants across rebuilds), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | tail -1
BIN=".build/release/AIUsageBar"
APP="dist/AIUsageBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIUsageBar"
cp Sources/AIUsageBar/Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/AIUsageBar/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# No -v on find-identity: a self-signed identity is untrusted, so it lists as invalid, yet codesign accepts it.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"AI Usage Bar Dev"'; then
    IDENTITY="AI Usage Bar Dev"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP" 2>/dev/null
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x AIUsageBar 2>/dev/null || true
    # Login items are bound to the bundle path; drop the dist/ one so only /Applications stays.
    "$APP/Contents/MacOS/AIUsageBar" --unregister-login 2>/dev/null || true
    rm -rf /Applications/AIUsageBar.app
    cp -R "$APP" /Applications/AIUsageBar.app
    echo "Installed to /Applications/AIUsageBar.app"
    open /Applications/AIUsageBar.app
fi
