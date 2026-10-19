#!/bin/zsh
# Builds Claude Profiler.app into ~/Applications and launches it.
set -e
cd "$(dirname "$0")"
APP=~/Applications/"Claude Profiler.app"
launchctl bootout gui/$(id -u)/com.azwedo.claude-profiler 2>/dev/null || true
pkill -x ClaudeProfiler 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp claude.svg AppIcon.icns "$APP/Contents/Resources/"
swiftc -O main.swift -o "$APP/Contents/MacOS/ClaudeProfiler"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Profiler</string>
  <key>CFBundleIdentifier</key><string>com.azwedo.claude-profiler</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ClaudeProfiler</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP"
# LaunchAgent: start at login and restart it if it ever exits.
PLIST=~/Library/LaunchAgents/com.azwedo.claude-profiler.plist
cat > "$PLIST" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.azwedo.claude-profiler</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClaudeProfiler</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
AGENT
launchctl bootstrap gui/$(id -u) "$PLIST"
