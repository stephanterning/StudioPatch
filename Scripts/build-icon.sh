#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="${STUDIOPATCH_BUILD_DIR:-$task_root/../../work/studiopatch-build}"
mkdir -p "$task_build"
task_iconset="$(mktemp -d "$task_build/app-icon.XXXXXX")/StudioPatch.iconset"
mkdir -p "$task_iconset"
for task_size in 16 32 128 256 512; do
    sips -z "$task_size" "$task_size" "$task_root/Resources/Brand/StudioPatch-logo-v1.png" \
        --out "$task_iconset/icon_${task_size}x${task_size}.png" >/dev/null
    task_retina=$((task_size * 2))
    sips -z "$task_retina" "$task_retina" "$task_root/Resources/Brand/StudioPatch-logo-v1.png" \
        --out "$task_iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns "$task_iconset" -o "$task_root/Resources/StudioPatch.icns"
