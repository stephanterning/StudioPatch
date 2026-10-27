#!/bin/bash
set -euo pipefail
task_fixtures="$(cd "$(dirname "$0")" && pwd)"
task_root="$(cd "$task_fixtures/../../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/studiopatch-review-f8b64d0.XXXXXX")"
printf 'Review artifacts: %s\n' "$task_build"
mkdir -p "$task_build"
clang++ -std=c++17 -c "$task_fixtures/RuntimeFake.cpp" -o "$task_build/runtime-fake.o"
xcrun swiftc -parse-as-library -swift-version 5 -D STUDIOPATCH_MODEL_TESTS -D STUDIOPATCH_FAKE_AUDIO \
    -module-cache-path "$task_build/swift-cache" -import-objc-header "$task_root/Sources/Bridge.h" \
    "$task_root/Sources/RuntimeTypes.swift" "$task_root/Sources/RuntimeController.swift" "$task_root/Sources/RuntimeConnection.swift" "$task_root/Sources/SessionStore.swift" "$task_root/Sources/Preset.swift" \
    "$task_root/Sources/Service.swift" "$task_build/runtime-fake.o" \
    -framework UserNotifications -framework AppKit -framework Foundation -lc++ -o "$task_build/runtime-test-service"
# Fail the test setup if a real HAL entry point leaked into the fake backend.
python3 - "$task_build/runtime-test-service" <<'PYHAL'
import subprocess,sys
symbols=subprocess.check_output(["nm","-u",sys.argv[1]],text=True)
assert not any(prefix in symbols for prefix in ["_AudioObject", "_AudioDevice", "_AudioHardware"]), symbols
print("PASS: fake runtime has no HAL query/listener/device entry points",flush=True)
PYHAL

clang++ -std=c++17 -fblocks -fobjc-arc -I "$task_root/Sources" \
    "$task_fixtures/NativeReview.mm" -framework Foundation -framework CoreAudio \
    -o "$task_build/native-review"
"$task_build/native-review" | tee "$task_build/native-results.txt"
python3 "$task_fixtures/runtime-review.py" "$task_build" | tee "$task_build/runtime-results.txt"
