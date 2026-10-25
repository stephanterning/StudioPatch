#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/work/ableton-channel-names"
source="$root/Tools/ableton-channel-names.swift"
binary="$cache/ableton-channel-names"
mkdir -p "$cache"
if [[ ! -x "$binary" || "$source" -nt "$binary" ]]; then
    xcrun swiftc -parse-as-library -module-cache-path "$cache/module-cache" "$source" -o "$binary"
fi
exec python3 "$root/Tools/sync-ableton-channel-names.py" --helper "$binary" "$@"
