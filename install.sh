#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.claude/bin"
APP_NAME="ClaudeLiveStatus"
BUNDLE_ID="com.claude.live-status"
WIDGET_BUNDLE_ID="com.claude.live-status.widget"
APP_DIR="$HOME/Applications/$APP_NAME.app"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="$BUNDLE_ID"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cd "$SCRIPT_DIR"

# Step 1: Build host app + hook CLI via Swift Package Manager
echo -e "${GREEN}[1/6] Building host app and hook CLI...${NC}"
swift build -c release 2>&1 | tail -5

# Step 2: Compile widget extension with swiftc
echo -e "${GREEN}[2/6] Building widget extension...${NC}"
swiftc -parse-as-library \
    -target arm64-apple-macos13.0 \
    -framework SwiftUI \
    -framework WidgetKit \
    -application-extension \
    -O \
    Sources/Widget/ClaudeWidget.swift \
    -o .build/release/ClaudeStatusWidget

# Step 3: Create .app bundle with embedded .appex
echo -e "${GREEN}[3/6] Creating app bundle...${NC}"

# Clean previous install
rm -rf "$APP_DIR"

# Host app bundle
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/PlugIns/ClaudeStatusWidget.appex/Contents/MacOS"

cp .build/release/ClaudeLiveStatus "$APP_DIR/Contents/MacOS/"

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Widget extension bundle
APPEX_DIR="$APP_DIR/Contents/PlugIns/ClaudeStatusWidget.appex"
cp .build/release/ClaudeStatusWidget "$APPEX_DIR/Contents/MacOS/"

cat > "$APPEX_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$WIDGET_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>ClaudeStatusWidget</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeStatusWidget</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST

# Step 4: Code sign (ad-hoc)
echo -e "${GREEN}[4/6] Signing bundles...${NC}"
codesign --force --sign - --deep "$APPEX_DIR"
codesign --force --sign - --deep "$APP_DIR"

# Step 5: Install hook binary + configure hooks
echo -e "${GREEN}[5/6] Installing hook and configuring Claude Code...${NC}"
mkdir -p "$INSTALL_DIR"
cp .build/release/claude-status-hook "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/claude-status-hook"

python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

hook_cmd = os.path.expanduser("~/.claude/bin/claude-status-hook")
settings.setdefault("hooks", {})

hook_configs = {
    "PreToolUse": "pre",
    "PostToolUse": "post",
    "Notification": "notify",
    "Stop": "stop",
}

for event, arg in hook_configs.items():
    existing = settings["hooks"].get(event, [])
    cleaned = []
    for entry in existing:
        hooks = [h for h in entry.get("hooks", []) if "claude-status-hook" not in h.get("command", "")]
        if hooks:
            entry["hooks"] = hooks
            cleaned.append(entry)
    cleaned.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": f"{hook_cmd} {arg}"}]
    })
    settings["hooks"][event] = cleaned

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("  Hooks written to ~/.claude/settings.json")
PYEOF

# Step 6: LaunchAgent + start
echo -e "${GREEN}[6/6] Setting up auto-start...${NC}"
mkdir -p "$LAUNCHAGENT_DIR"
cat > "$LAUNCHAGENT_DIR/$PLIST_NAME.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DIR/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCHAGENT_DIR/$PLIST_NAME.plist"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  App bundle:    $APP_DIR"
echo "  Widget:        $APP_DIR/Contents/PlugIns/ClaudeStatusWidget.appex"
echo "  Hook binary:   $INSTALL_DIR/claude-status-hook"
echo "  LaunchAgent:   $LAUNCHAGENT_DIR/$PLIST_NAME.plist"
echo ""
echo "  The menu bar icon should appear now (✦ sparkle)."
echo "  To add the widget: right-click desktop → Edit Widgets → search 'Claude'"
echo ""
echo -e "${YELLOW}To uninstall:${NC}"
echo "  launchctl bootout gui/$(id -u)/$PLIST_NAME"
echo "  rm -rf \"$APP_DIR\""
echo "  rm \"$INSTALL_DIR/claude-status-hook\""
echo "  rm \"$LAUNCHAGENT_DIR/$PLIST_NAME.plist\""
echo "  # Then remove hook entries from ~/.claude/settings.json"
