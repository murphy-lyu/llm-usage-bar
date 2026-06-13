#!/bin/bash
# Builds a release binary and assembles LLMUsageBar.app (a menu-bar-only app).
set -e
cd "$(dirname "$0")"

echo "▸ swift build -c release"
swift build -c release

APP="LLMUsageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/LLMUsageBar" "$APP/Contents/MacOS/LLMUsageBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>LLMUsageBar</string>
    <key>CFBundleDisplayName</key>     <string>LLM Usage Bar</string>
    <key>CFBundleIdentifier</key>      <string>local.llmusagebar</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>      <string>LLMUsageBar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will run it without quarantine hassle.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ Built $APP"
echo "  Run:        open $APP"
echo "  Install:    cp -r $APP /Applications/"
