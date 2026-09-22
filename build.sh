#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="QuietTimer.app"
EXECUTABLE="$APP/Contents/MacOS/QuietTimer"

mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QuietTimer</string>
<key>CFBundleIdentifier</key><string>local.penggao.quiettimer</string>
<key>CFBundleName</key><string>静时</string>
<key>CFBundleDisplayName</key><string>静时</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

xcrun swiftc main.swift -o "$EXECUTABLE" -framework SwiftUI -framework AppKit
codesign --force --sign - "$APP"
xattr -cr "$APP"
open "$APP"

echo "QuietTimer.app is ready."
