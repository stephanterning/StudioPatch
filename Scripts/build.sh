#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="${STUDIOPATCH_BUILD_DIR:-$task_root/build}"
task_dist="${STUDIOPATCH_DIST_DIR:-$task_root/Dist}"
# Use a persistent certificate identity; never silently fall back to ad-hoc signing.
task_identity="${STUDIOPATCH_SIGNING_IDENTITY:-}"
if [[ -z "$task_identity" && -f "$task_root/Scripts/signing-identity.txt" ]]; then
    task_identity="$(cat "$task_root/Scripts/signing-identity.txt")"
fi
if [[ -z "$task_identity" ]]; then
    echo "Set STUDIOPATCH_SIGNING_IDENTITY or create Scripts/signing-identity.txt with your signing certificate identity." >&2
    exit 1
fi
cmake -S "$task_root" -B "$task_build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$task_build" -j4
ctest --test-dir "$task_build" --output-on-failure
task_stage="$(mktemp -d "$task_build/package.XXXXXX")"
mkdir -p "$task_stage/StudioPatch.app/Contents/MacOS" "$task_stage/StudioPatch.driver/Contents/MacOS" "$task_dist"
xcrun swiftc -parse-as-library -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$task_build/swift-cache" \
    -import-objc-header "$task_root/Sources/Bridge.h" \
    "$task_root/Sources/RuntimeTypes.swift" "$task_root/Sources/RuntimeController.swift" "$task_root/Sources/RuntimeConnection.swift" "$task_root/Sources/SessionStore.swift" "$task_root/Sources/Preset.swift" "$task_root/Sources/Matrix.swift" "$task_root/Sources/MatrixGroups.swift" "$task_root/Sources/AbletonLabels.swift" "$task_root/Sources/AbletonToolsView.swift" "$task_root/Sources/App.swift" "$task_build/libpatchbridge.a" \
    -framework UserNotifications -framework SwiftUI -framework AppKit -framework Foundation -framework CoreAudio -lc++ \
    -o "$task_stage/StudioPatch.app/Contents/MacOS/StudioPatch"
xcrun swiftc -parse-as-library -swift-version 5 -O -D STUDIOPATCH_MODEL_TESTS \
    -module-cache-path "$task_build/swift-cache" -import-objc-header "$task_root/Sources/Bridge.h" \
    "$task_root/Sources/RuntimeTypes.swift" "$task_root/Sources/RuntimeController.swift" "$task_root/Sources/RuntimeConnection.swift" "$task_root/Sources/SessionStore.swift" "$task_root/Sources/Preset.swift" \
    "$task_root/Sources/ServiceRecovery.swift" "$task_root/Sources/Service.swift" "$task_build/libpatchbridge.a" \
    -framework UserNotifications -framework AppKit -framework Foundation -framework CoreAudio -lc++ \
    -o "$task_stage/StudioPatch.app/Contents/MacOS/StudioPatchService"
codesign --force --identifier se.studiopatch.app --sign "$task_identity" "$task_stage/StudioPatch.app/Contents/MacOS/StudioPatchService"
xcrun swiftc -parse-as-library -swift-version 5 -O -D STUDIOPATCH_ABLETON_EMBEDDED -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$task_build/swift-cache" \
    "$task_root/Sources/AbletonLabels.swift" "$task_root/Tools/ableton-channel-names.swift" "$task_root/Tools/update-ableton-labels.swift" \
    -framework AppKit -framework Foundation -framework CoreAudio \
    -o "$task_stage/StudioPatch.app/Contents/MacOS/StudioPatchAbletonLabels"
codesign --force --sign "$task_identity" "$task_stage/StudioPatch.app/Contents/MacOS/StudioPatchAbletonLabels"
cp "$task_build/StudioPatch" "$task_stage/StudioPatch.driver/Contents/MacOS/StudioPatch"
cp "$task_root/Resources/App-Info.plist" "$task_stage/StudioPatch.app/Contents/Info.plist"
mkdir -p "$task_stage/StudioPatch.app/Contents/Resources"
cp "$task_root/Resources/StudioPatch.icns" "$task_stage/StudioPatch.app/Contents/Resources/StudioPatch.icns"
cp "$task_root/Resources/Driver-Info.plist" "$task_stage/StudioPatch.driver/Contents/Info.plist"
cp "$task_build/patch-inspect" "$task_dist/patch-inspect"
cp "$task_build/StudioPatchBroker" "$task_dist/StudioPatchBroker"
codesign --force --identifier se.studiopatch.broker --sign "$task_identity" "$task_dist/StudioPatchBroker"
codesign -d -r- "$task_stage/StudioPatch.app/Contents/MacOS/StudioPatchService" 2>&1 | sed -n 's/^designated => //p' > "$task_dist/service.requirement"
codesign --force --sign "$task_identity" "$task_stage/StudioPatch.app"
codesign --force --sign "$task_identity" "$task_stage/StudioPatch.driver"
codesign --verify --strict "$task_stage/StudioPatch.app"
codesign --verify --strict "$task_stage/StudioPatch.driver"
# Do not overwrite executable pages belonging to a running test instance.
for task_bundle in StudioPatch.app StudioPatch.driver; do
    if [[ -e "$task_dist/$task_bundle" ]]; then mv "$task_dist/$task_bundle" "$task_stage/previous-$task_bundle"; fi
    mv "$task_stage/$task_bundle" "$task_dist/$task_bundle"
done
echo "Built and tested: $task_dist"
echo "Nothing was installed. The driver has not been loaded by Core Audio."
