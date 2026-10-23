#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="${STUDIOPATCH_BUILD_DIR:-$task_root/../../work/build}"
mkdir -p "$task_build"
xcrun swiftc -parse-as-library -swift-version 5 \
    "$task_root/Sources/ServiceRecovery.swift" "$task_root/Tests/ServiceRecoveryTests.swift" \
    -o "$task_build/service-recovery-tests"
"$task_build/service-recovery-tests"
clang++ -std=c++17 -c "$task_root/Tests/RuntimeFake.cpp" -o "$task_build/runtime-fake.o"
xcrun swiftc -parse-as-library -swift-version 5 -D STUDIOPATCH_MODEL_TESTS -D STUDIOPATCH_FAKE_AUDIO \
    -module-cache-path "$task_build/swift-cache" -import-objc-header "$task_root/Sources/Bridge.h" \
    "$task_root/Sources/RuntimeTypes.swift" "$task_root/Sources/RuntimeController.swift" "$task_root/Sources/RuntimeConnection.swift" "$task_root/Sources/SessionStore.swift" "$task_root/Sources/Preset.swift" \
    "$task_root/Sources/ServiceRecovery.swift" "$task_root/Sources/Service.swift" "$task_build/runtime-fake.o" \
    -framework UserNotifications -framework AppKit -framework Foundation -lc++ -o "$task_build/runtime-test-service"
# Fail the test setup if a real HAL entry point leaked into the fake backend.
python3 - "$task_build/runtime-test-service" <<'PYHAL'
import subprocess,sys
symbols=subprocess.check_output(["nm","-u",sys.argv[1]],text=True)
assert not any(prefix in symbols for prefix in ["_AudioObject", "_AudioDevice", "_AudioHardware"]), symbols
print("PASS: fake runtime has no HAL query/listener/device entry points",flush=True)
PYHAL
task_fixture="$(mktemp -d "$task_build/runtime-test.XXXXXX")"
python3 "$task_root/Tests/RuntimeIntegration.py" "$task_build/runtime-test-service" "$task_fixture"
