#!/bin/bash
# Builds build/JiraBar.app (no Xcode project needed — only the Swift toolchain).
#   Scripts/build_app.sh             build only
#   Scripts/build_app.sh --install   build, copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/JiraBar.app"
source Scripts/env.sh

swift build -c release ${SDK_ARGS[@]+"${SDK_ARGS[@]}"}
BIN="$(swift build -c release ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/JiraBar" "$APP/Contents/MacOS/JiraBar"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>JiraBar</string>
    <key>CFBundleDisplayName</key><string>JiraBar</string>
    <key>CFBundleIdentifier</key><string>com.mohamadvahedi.jirabar</string>
    <key>CFBundleExecutable</key><string>JiraBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    pkill -x JiraBar 2>/dev/null || true
    sleep 0.5
    rm -rf "$HOME/Applications/JiraBar.app"
    cp -R "$APP" "$HOME/Applications/JiraBar.app"
    open "$HOME/Applications/JiraBar.app"
    echo "Installed to ~/Applications/JiraBar.app and launched."
fi
