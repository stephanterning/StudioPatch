# Architecture review — current action register

Source: revision 2 (16:55) of ARCHITECTURE-REVIEW-2026-10-23.md, plus the follow-up review. All 19 findings have an explicit disposition. “Implemented” does not imply every physical failure mode has been qualified.

## Review closure — 2026-10-23

**Status: CLOSED — architecture review and remediation completed, with explicit qualification limitations.** Closure was authorized by the user after installation and the final monitored audio check. All 19 findings are addressed through implemented corrections or documented rejections/accepted tradeoffs. This is not a claim of full hardware release qualification.

Remaining verification is retained as follow-up work:

- Physical recovery after a live broker outage, forced sleep/wake, lost clock synchronization, and process-image replacement against an actually failed HAL connection.
- Attribution of the historical global Core Audio CPU/enumeration runaway; its root cause remains unknown.

These items are not marked passed or silently discarded. Disruptive verification is excluded on this working workstation and requires a separate controlled setup. The accepted latency, interface-alignment and graph-restart limitations remain in the findings table. No further tests were run for closure or this commit; all verification results below predate closure.

## Current state and deployment boundary

- **Installed:** the final-review app/service, including preserved HAL inventory error codes, bounded recovery and its allocation-failure guard. The installed driver and broker retain their earlier matching versions. The deployment and short monitored hardware result are recorded below.
- **Offline review completed:** recovery-budget failure tests, fake-runtime HAL isolation and stronger process-image assertions remain in the source/test suite. No review correction is waiting for installation in the app/service bundle.
- **Latest deployment scope:** only the app/user-service bundle was updated and that user service restarted. Core Audio and broker processes and installed driver/broker files were checked unchanged (`work/review-hardware/final-install-audit.json`). The preceding offline pass made no live changes; its file audit remains historical evidence.
- **Open investigation:** the root cause of the historical global Core Audio CPU/enumeration runaway is unknown. Application containment is implemented; the system-level cause is not claimed fixed.
- **Excluded on this workstation:** deliberate broker outages, Core Audio restart/fault injection, physical clock-unlock and forced sleep/wake. Their physical qualification remains absent, not passed by inference from simulations.

The full chronological evidence and superseded status messages are in [the history archive](REVIEW-HISTORY-2026-10-23.md). This document is the authoritative current summary.

## Findings and dispositions

| ID | Current disposition | Verification / retained limitation |
|---|---|---|
| C1 | Fixed with an accepted latency tradeoff. | Full-buffer minimum padding passes 48/96 kHz regressions. Added transport RTL at 48 kHz is 1.333 ms, exceeding the original 1 ms target. |
| C2 | Routing changes fixed; broader restart optimization rejected for this implementation. | Unaffected audio continuity and zero format notifications measured during route edits. Adding/removing interfaces can still restart the graph. |
| C3 | Clock consistency, epochs and stale-clock muting implemented. | Deterministic tests, normal hardware and simulated invalidation/rebuild pass. Forced physical jumps and sleep/wake are not qualified. |
| C4 | Rate-scalar calculation fixed. | Injected-scalar tests and normal hardware runs pass. |
| C5 | Nonblocking driver transport and bounded service recovery implemented. Final inventory-path correction is installed. | Historical cold broker-present/absent/reconnect tests passed with matching driver code. Lookup fallback, blocked calls, persistent errors and restart limiting tested in isolation. Global HAL failure cause remains unknown. |
| H1 | Secondary timestamp supervision and latency display implemented. Common alignment and automatic unmuting without clock-lock evidence rejected. | Normal-operation soak and injected drift/jitter tests pass. Secondary mute remains latched. No direct ADAT lock-bit supervision or physical lock-loss qualification; earlier startup skew remains unexplained. |
| H2 | Replacing sample-validity tags rejected after profiling. | Existing tags preserve gap/wrap correctness. Synthetic timing is recorded in the archive; it is not an end-to-end deadline guarantee. |
| H3 | Measurement support implemented within stated scope. | Timing A/B and waveform comparisons verified. Phase estimates are projected, not proof of exact shared boundaries; multiple-client attribution is unsupported. Phase-shift PoC stays disabled. |
| H4 | Listener lifetime fixed. | Ownership tests and earlier restart/hardware runs pass. |
| H5 | Authenticated custom writes and claim renewal implemented. | Signed acceptance, unsigned rejection and live user-service revocation/reclaim passed. Cache renewal after revocation is regression-tested. Latest live warm-broker outage was deliberately not induced. |
| M1 | Runtime controller extracted from UI; unused policy removed. | Real controller integration tests use a fake audio backend. Final test build also removes real HAL listener calls. |
| M2 | File/HAL event-driven refresh implemented; full XPC migration rejected for this iteration. | Atomic session replacement and retry/inventory tests pass. One-second recovery/status heartbeat and five-second inventory fallback remain intentional. |
| M3 | Legacy engine removed from production path. | Production exposes one direct endpoint without legacy rings. Explicit legacy test builds remain. |
| M4 | Sample-rate validation fixed. | Shared finite/integral/range checks and hardware-range constraints; boundary tests pass. |
| M5 | Margin ownership fixed. | Direct engine owns active margins. Obsolete preset fields remain only for compatibility. |
| L1 | Interactive process-priority change rejected as unproven. | No measured control-response benefit justifies the change. |
| L2 | Access/signing limitations documented. | Active-console user and matching broker/service signing requirement remain product constraints. |
| L3 | Broker mapping lifetime fixed. | Broker retains current mapping; existing peers retain their own mappings across generation changes. |
| L4 | Client-lifecycle lock contention fixed. | Deterministic blocked-start/timestamp regression, synthetic profile and physical client churn passed. Stack is not claimed lock-free. |

## Final offline code/test review

### Findings corrected during the offline review (now installed)

1. **Inventory could bypass recovery.** `SPInventory` swallowed native HAL errors while resolving the virtual device/configuration. The controller then reported “not installed” instead of recognizing a persistent bad-object error. Optional `driverErrorStatus` now preserves that code while retaining the physical-device inventory. Missing selected hardware still takes precedence. An isolated integration case verifies that an inventory failure reaches the recovery circuit breaker without hiding hardware.
2. **Fake runtime still registered HAL listeners.** Audio I/O was mocked, but `DeviceInventoryObserver` remained real. The dedicated `STUDIOPATCH_FAKE_AUDIO` build now excludes the real observer and its calls. The test script checks the executable's undefined symbols and refuses a fake binary with AudioObject/AudioDevice/AudioHardware entry points.
3. **Recovery tests could accept stale evidence.** A new launch could read the prior process's running snapshot. Tests now remove stale snapshots before relaunch and count initialization of each process image. Recovery must actually replace the image, not merely write the budget file.
4. **Unverified failure paths.** Recovery budget logic is extracted without changing its normal ten-minute policy. Tests cover exact cooldown boundary, backward/invalid clocks, corrupt/wrong-type/unreadable state, write failure, preservation of the old budget on failure, and missing parent directory. Real fake-service cases cover corrupt budget and a removed executable, requiring successful exit, durable stopped status, unchanged settings and no second process image. An allocation failure now also stops explicitly.

No automatic secondary unmute or shorter watchdog/cooldown was introduced. During the offline pass production artifacts were compiled for checking only and installed services were untouched. The subsequent explicitly authorized deployment installed the app/service corrections; see the deployment result below.

### Verification and evidence

- Final isolated run: `work/review-hardware/final-offline-complete.log` (budget tests, symbol isolation gate and full runtime integration).
- Native bridge compile: `final-offline-bridge-build.log`; production service compile only: `final-offline-service-build.log`.
- Previous full CTest run: eight suites passed (`recovery-final-ctest.log`). That is historical evidence; this pass does not claim a new full hardware-linked suite run.
- An earlier intermediate test command ended with a shell error because its script was edited while executing. Its individual output is retained in `final-offline-runtime.log`, but the command is **not** counted as a passing suite. The final run uses the completed, unchanged script.

## Saved-log analysis

Analysis uses retained files only; it does not query the live audio system. Machine-readable extraction: `work/review-hardware/final-offline-log-analysis.json`.

| Observation | Supported conclusion | What it does not establish |
|---|---|---|
| At 19:12:15 launchd reported that Core Audio had run for two seconds and delayed respawn by eight seconds (`coreaudio-restart-launchd.log:70`). | An old six-second readiness deadline could expire before respawn. Some test failures/rollbacks were caused by the harness. | It does not explain every later timeout or the CPU runaway. |
| A retained service stack waits inside `AudioDeviceStart` → `StartAndWaitForState` → `_WaitForState` (`recovery-service-sample.txt`). | A control call can block below the service; ordinary retry code cannot run until it returns. | A waiting stack is not evidence that this thread caused high CPU. |
| For the post-reboot service PID 952, ZED start failed at 19:43:00.880 (35) and 19:43:18.451 (`nope`). Old object ID 149 then disappeared. | Device-start/re-enumeration trouble preceded persistent lookup failures in that service. | Temporal order does not prove that ZED caused the global HAL problem. |
| That same PID logged 166 bad-object lines and 83 missing-proxy lines from 19:43:18.723 to 19:47:03.974. A fresh process subsequently resolved StudioPatch. | The error persisted for minutes; it was not just one transient readiness miss. Independent lookup and bounded process replacement address observed failure paths. Counts are log lines, not distinct incidents. | It does not establish the exact internal HAL cache failure or validate real HAL recovery by process-image replacement. |
| A separate broker-recovery batch still had no controller after a full 30-second budget (`ready-system-batch/results.json`). | That failure was real; the unchanged-rate authorization-cache defect was subsequently corrected and regression-tested. | Earlier one-second failures are not equivalent evidence, and the latest live warm-broker outage remains untested. |

These are separate incidents, including different boots and harness versions. They must not be merged into a single claimed root cause. Existing evidence supports the application fixes but cannot attribute the global CPU runaway.

## Remaining work and release boundary

1. The latest inventory-path correction and small recovery hardening are installed. Their simulated-failure tests and the ordinary-audio smoke test have distinct scopes; a normal capture does not prove recovery from every physical fault.
2. Real broker interruption, clock unlock, sleep/wake and process-image recovery against a failed HAL connection require a separate controlled test setup before they can be called physically qualified.
3. Root-cause attribution for global Core Audio runaway remains open. Repeated fault injection on this working workstation is rejected.
4. Accepted limitations (48 kHz target miss, inter-interface skew, graph restarts, disabled phase-shift PoC) are deliberate dispositions, not forgotten tasks.

## Latest deployment and short monitored audio check

The final app/service was built from the reviewed sources, signed with the existing Developer ID identity and verified against the installed broker's signing requirement. The prior app bundle is retained at `work/final-review-package/previous-StudioPatch.app`. No driver/broker installer or system-service restart was used; only the user launch agent was stopped and started to load the new app/service.

The **15-second** loopback at 96 kHz, engine 32/client 256, idle synthetic load passed: continuous timestamps, fixed **729-frame RTL**, **zero differing windows out of 17,400** against the qualified analog reference (minimum correlation 0.999756). The two raw short-window input/output threshold crossings are not counted as dropouts: the received-waveform reference comparison passes. The engine generation stayed constant, every sampled status was running, and neither interface registered a clock fault. Peak sampled Core Audio CPU was **32.8% of one core**.

Core Audio PID **636** and broker PID **592** remained unchanged. Driver, broker and broker signing-requirement hashes also remained unchanged. Session and presets compare equal to their pre-update contents; 96 kHz, engine 32 and original routes remain active, with no test environment overrides. The capture process has exited. No forced physical error was induced, so the physical qualification limits above remain explicit.

Evidence: `work/review-hardware/final-install-audit.json`, `final-install-app-build.log`, `final-installed-96k-*`, and `final-installed-state.json`.
