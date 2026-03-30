#!/bin/bash

PLIST_NAME="com.claude.live-status"
APP_DIR="$HOME/Applications/ClaudeLiveActivity.app"
INSTALL_DIR="$HOME/.claude/bin"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"

echo "Stopping ClaudeLiveActivity..."
launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null
pkill -f ClaudeLiveActivity 2>/dev/null

echo "Removing files..."
rm -rf "$APP_DIR"
rm -f "$INSTALL_DIR/claude-status-hook"
rm -f "$LAUNCHAGENT_DIR/$PLIST_NAME.plist"
rm -rf "$HOME/.claude/live-sessions"

echo "Removing hooks from settings..."
python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
if not os.path.exists(settings_path):
    exit()

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for event in ["PreToolUse", "PostToolUse", "Notification", "Stop"]:
    entries = hooks.get(event, [])
    cleaned = []
    for entry in entries:
        entry["hooks"] = [h for h in entry.get("hooks", []) if "claude-status-hook" not in h.get("command", "")]
        if entry["hooks"]:
            cleaned.append(entry)
    if cleaned:
        hooks[event] = cleaned
    elif event in hooks:
        del hooks[event]

settings["hooks"] = hooks
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("  Hooks removed from ~/.claude/settings.json")
PYEOF

echo "Uninstalled."
