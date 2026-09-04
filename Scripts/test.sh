#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
interface_file="$sdk_dir/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
cache_dir="$project_dir/.cache/clang26-tests"
output="$project_dir/.build/playback-prebuffer-tests"

if [[ ! -f "$interface_file" ]]; then
  print -u2 "A macOS Tahoe SDK is required. Install current Xcode or Command Line Tools."
  exit 1
fi

interface_version="$(sed -n '2s|// swift-compiler-version: ||p' "$interface_file")"
mkdir -p "${output:h}" "$cache_dir"
CLANG_MODULE_CACHE_PATH="$cache_dir" swiftc \
  -sdk "$sdk_dir" \
  -target arm64-apple-macosx26.0 \
  -interface-compiler-version "$interface_version" \
  -o "$output" \
  "$project_dir/Sources/JellyPlayer/LoxoneClient.swift" \
  "$project_dir/Sources/JellyPlayer/DisplaySynchronization.swift" \
  "$project_dir/Sources/JellyPlayer/PlaybackPrebuffer.swift" \
  "$project_dir/Tests/PlaybackPrebufferTests.swift"
"$output"
