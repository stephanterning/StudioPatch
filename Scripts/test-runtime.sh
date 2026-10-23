#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="${STUDIOPATCH_BUILD_DIR:-$task_root/../../work/build}"
mkdir -p "$task_build"
clang++ -std=c++17 -c "$task_root/Tests/RuntimeFake.cpp" -o "$task_build/runtime-fake.o"
xcrun swiftc -parse-as-library -swift-version 5 -D STUDIOPATCH_MODEL_TESTS \
    -module-cache-path "$task_build/swift-cache" -import-objc-header "$task_root/Sources/Bridge.h" \
    "$task_root/Sources/RuntimeConnection.swift" "$task_root/Sources/SessionStore.swift" "$task_root/Sources/Preset.swift" \
    "$task_root/Sources/Matrix.swift" "$task_root/Sources/App.swift" "$task_root/Sources/Service.swift" "$task_build/runtime-fake.o" \
    -framework UserNotifications -framework SwiftUI -framework AppKit -framework Foundation -lc++ -o "$task_build/runtime-test-service"
task_fixture="$(mktemp -d "$task_build/runtime-test.XXXXXX")"
python3 "$task_root/Tests/RuntimeIntegration.py" "$task_build/runtime-test-service" "$task_fixture"
