#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
agent_dir="$HOME/Library/LaunchAgents"
agent_path="$agent_dir/org.tcox.silver.plist"
domain="gui/$(id -u)"

mkdir -p "$agent_dir"
cp "$project_dir/Resources/org.tcox.silver.plist" "$agent_path"
plutil -lint "$agent_path"
launchctl bootout "$domain/org.tcox.silver" 2>/dev/null || true
launchctl bootstrap "$domain" "$agent_path"
launchctl enable "$domain/org.tcox.silver"

print "Silver will start automatically when this user logs in."
