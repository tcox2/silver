#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
interface_file="$sdk_dir/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
output_dir="$project_dir/.build/direct"
cache_dir="$project_dir/.cache/clang26"
bundle_dir="$project_dir/.build/Silver-build.app.disabled"
jellyfin_frameworks="/Applications/Jellyfin Desktop.app/Contents/Frameworks"

if [[ ! -f "$interface_file" ]]; then
  print -u2 "A macOS Tahoe SDK is required. Install current Xcode or Command Line Tools."
  exit 1
fi

interface_version="$(sed -n '2s|// swift-compiler-version: ||p' "$interface_file")"
mkdir -p "$output_dir" "$cache_dir"
ln -sfn "$jellyfin_frameworks" "$project_dir/.build/Frameworks"

CLANG_MODULE_CACHE_PATH="$cache_dir" swiftc \
  -parse-as-library \
  -sdk "$sdk_dir" \
  -target arm64-apple-macosx26.0 \
  -interface-compiler-version "$interface_version" \
  -o "$output_dir/Silver" \
  "$project_dir"/Sources/JellyPlayer/*.swift

mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$output_dir/Silver" "$bundle_dir/Contents/MacOS/Silver"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
printf 'APPL????' > "$bundle_dir/Contents/PkgInfo"
if [[ -L "$bundle_dir/Contents/Frameworks" ]]; then
  unlink "$bundle_dir/Contents/Frameworks"
fi
mkdir -p "$bundle_dir/Contents/Frameworks"
chmod -R u+w "$bundle_dir/Contents/Frameworks"
cp -f "$jellyfin_frameworks"/*.dylib "$bundle_dir/Contents/Frameworks/"
codesign --force --deep --sign - "$bundle_dir"

print "Built $output_dir/Silver"
print "Packaged $bundle_dir"
