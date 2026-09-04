#!/bin/zsh
set -euo pipefail

server=${1:?usage: install-updater.sh <nats-url> <nats-token-file>}
source_token=${2:?usage: install-updater.sh <nats-url> <nats-token-file>}
[[ $server == tls://* ]] || { print -u2 "NATS URL must use TLS"; exit 1; }
[[ -r $source_token ]] || { print -u2 "NATS token file is not readable"; exit 1; }

state_dir="$HOME/Library/Application Support/Silver/Updater"
agent_dir="$HOME/Library/LaunchAgents"
token_file="$state_dir/nats-token"
config_file="$state_dir/updater.conf"
agent_file="$agent_dir/org.tcox.silver-updater.plist"
domain="gui/$(id -u)"

mkdir -p "$state_dir" "$agent_dir" "$HOME/Library/Logs/Silver"
umask 077
cp "$source_token" "$token_file"
printf 'NATS_URL=%q\nNATS_TOKEN_FILE=%q\n' "$server" "$token_file" > "$config_file"
chmod 600 "$token_file" "$config_file"
cp /Applications/Silver.app/Contents/Resources/org.tcox.silver-updater.plist "$agent_file"
chmod 600 "$agent_file"
plutil -lint "$agent_file"
launchctl bootout "$domain/org.tcox.silver-updater" 2>/dev/null || true
launchctl bootstrap "$domain" "$agent_file"
launchctl enable "$domain/org.tcox.silver-updater"
print "Silver NATS updater installed."
