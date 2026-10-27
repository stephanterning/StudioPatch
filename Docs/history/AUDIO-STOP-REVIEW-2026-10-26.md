# Audio-stop review and implementation — 2026-10-26

Hand-over from a second review of the automatic audio stops recorded in the [STATUS audit](../STATUS.md). It is written for the agent that performed that audit, so that agent can review this review and its implementation. All work is in one commit; nothing was installed or pushed.

## Owner requirement and decisions

The owner's requirement: StudioPatch is for professional users. Nothing automatic may silence connected, working audio. A user hears clock problems as distortion and handles them; StudioPatch should not add belt-and-braces logic for that. Prefer straight paths over defensive complexity.

Decisions the owner made for this round:

1. Implement every proposed action, including the driver change.
2. If a locked secondary cannot follow a sample-rate change, start anyway and report it.
3. Whether to keep any automatic process restart was delegated to the implementer. It was removed entirely; see "Trade-offs" below.
4. Clarified afterwards: keep helpful automation such as sync lock. Locked secondaries should still be set to the Sync Source's rate. A failure must never stop anything; audio continues with a status message.
5. The owner chose manual recovery for a persistent Core Audio "bad object" error, but without Terminal. The panel therefore has a **Restart audio service** button while audio is off, and the same command in the StudioPatch menu (`launchctl kickstart -k`). StudioPatch never restarts itself; launchd still restarts the service after a crash (`KeepAlive` on unsuccessful exit), as before.

The rule now in `CONTRIBUTING.md`: only confirmed physical disconnection and an applied configuration change that needs a rebuild may stop running audio. Everything else is reported.

## Verdict on the previous audit

All six findings were confirmed in the code. Two needed nuance.

| Audit finding | Verdict | Change |
|---|---|---|
| Broad exception handler stops healthy audio | Confirmed; this is the root cause. It also covered `SPRuntimeRates` (called every heartbeat) and transient driver-config read failures (`driverErrorStatus`/`installed`), which the audit did not name. | `runtimeTick` split into maintenance and apply. Only `withdrawIfDisconnected` and `rebuild` call `stopEngine()`. |
| Inventory omission stops before disconnection is confirmed | Confirmed. | New `SPMissingDevices` (UID lookup + alive flag) is consulted before stopping. A failed read counts as present. The `missingUIDs` check in `SPSetDeviceAvailable` was removed so there is one authoritative check. |
| Control watchdog can terminate the service permanently | Confirmed, and broader: the bad-object counter (3 errors over 10 s) took the same `execv`/`_exit(0)` path. `_exit(0)` also defeats the LaunchAgent's own `KeepAlive.SuccessfulExit=false` + `ThrottleInterval=5`. | `ServiceRecovery`, the watchdog, the bad-object counter, `recovery-attempt.json`, `recoveryStopped` and their tests removed. |
| Any watched property notification invalidates the whole engine | Confirmed. Nuance: not a permanent latch by itself. The controller saw `invalidated` and rebuilt within about a second. The cost was a full interruption plus two DAW-visible configuration changes per rebuild (`SPConfigure` always makes a fresh direct session; `publishLatency` requests a second change), and permanent silence whenever any start gate then failed. | Engine listeners removed. `DirectEngine::stale()` compares each interface's layout, buffer size, safety offsets and latency with the built graph; `SPStatus` reports it, and the controller rebuilds once on a difference. |
| One malformed block latches all callbacks off | Confirmed, with the same nuance. | The block is counted and skipped; no shared flag. The `invalidated` member is gone. |
| Rejected reconfiguration leaves the old session disabled | Confirmed in the driver. In practice the service had already stopped its engine before `SPConfigure`, so the real defect was tearing down before knowing the change could be applied. | The driver no longer clears `ready` before HAL performs a change, nor on a client rate request. |

The audit's further gates:

- Latency above 131072 frames: now clamped, since the driver accepts at most 131072.
- Safety-offset confirmation: bounded to 2 s while the transport is still silent, and no longer fatal.
- 2 s rate confirmation: now a warning.
- Handover timeout: practically unreachable, because `RouteSlot::passed` waits only for a callback already in progress. It now stops waiting instead of throwing.
- `SPConfigure`'s 5 s HAL confirmation: still fails the rebuild. It is part of applying a change and is retried.

## Additional findings (not in the audit)

All of these were static traces during review. Each now has a test, except where noted.

1. **Stored routes to channels that no longer exist abort the whole engine start.** The panel validates channels only when a route is created and never prunes routes when an interface later exposes fewer channels, for example ADAT/MADI at double speed. `DirectEngine::start`'s resolver threw for the entire graph. The same throw in `updateRouting` went through the broad handler and stopped a running engine. Now `compile()` skips the route (that destination stays silent) and lists it in status. Covered in `direct-tests`.
2. **A client rate request silenced the endpoint immediately and possibly indefinitely.** The driver's `SetNominalSampleRateImpl` cleared `ready` before anything was tried. `SPSetHardwareRate` then called `engine.reset()` before checking that locked members supported the rate. An unsupported rate (e.g. 192 kHz with a locked ZED) threw, was never acknowledged, and stayed silent. Now the driver only forwards the request. `SPSetHardwareRate` sets the Sync Source, then locked members follow the rate it actually reached. Failures are warnings, the engine runs at the actual Sync Source rate, and the request is acknowledged. Covered in `core-tests` and the runtime suite.
3. **A broker restart could stop running audio.** `SPRuntimeRates` calls `authorizeWrites()` every heartbeat. After a broker restart, the claim is revoked and reconnection fails until the driver re-registers about 2 s later. That failure reached the broad handler. It is now a status note. There is no dedicated test; the generic rate-query failure test covers the controller path.
4. **Publication failures tore down a started engine.** `setDeviceAvailable(true)` waited up to 2 s for the first hardware clock and up to 2 s for HAL's device list, then threw into the handler. Now the clock is checked once, and an unpublished endpoint is retried by `maintain()` on later heartbeats while audio runs. Covered in the runtime suite.
5. **A secondary that could not open or start failed the whole start.** Now it is reported and left out. Only a Sync Source failure fails the start. Not covered: needs real HAL.
6. **Found while implementing: a secondary's sample counter restart.** After the engine listeners were removed, a secondary whose counter restarts would write to stale timeline positions. This happens, for example, when its rate is set. Its routes would stay silent until the next rebuild. The callback now realigns when the counter moves backwards. Covered in `direct-tests`.

## Implementation by file

- `Sources/RuntimeController.swift`: rewritten tick.
  - `loadDesired` keeps the last readable preset.
  - Inventory failures become notes.
  - `withdrawIfDisconnected` stops only after confirmation.
  - Driver problems become notes while running.
  - `update()` handles the steady state through `maintain()` (names and publication, never stopping), routing-only updates (a failure is a note) and `rebuild()`. `applyFailed()` keeps the existing notification and retry schedule.
- `Sources/Service.swift`: no recovery closure. `Sources/ServiceRecovery.swift` deleted.
- `Sources/RuntimeConnection.swift`, `RuntimeTypes.swift`:
  - `recoveryStopped` removed.
  - `EngineStatus` gained `stale` and `warnings` and lost `invalidated`.
  - Format notifications carry rate warnings.
  - "Audio is muted" became "Audio is off".
- `Sources/DirectEngine.hpp`:
  - No listeners and no `invalidated`.
  - Shared `compile()` for `start` and `updateRouting`, which resolves routes by UID instead of a HAL lookup.
  - `openDevice()` contains each interface's failure.
  - `stale()`.
  - Buffer-size set failure is non-fatal; the engine uses the buffer the device reports.
- `Sources/Bridge.mm`, `Bridge.h`:
  - Listener helpers and `LegacyEngine` removed.
  - `SPMissingDevices` added.
  - `SPSetHardwareRate` returns `{rate, warnings}`.
  - `SPSetDeviceAvailable` does a single clock check.
  - `SPStatus` reports `stale` and `warnings`.
- `Sources/Driver.cpp`: `ready` is cleared only on retirement.
- Tests:
  - `RouteTests.mm` removed, because it tested only `LegacyEngine`.
  - `ServiceRecoveryTests.swift` removed.
  - `DirectTests.mm`, `CoreTests.cpp`, `RuntimeFake.cpp` and `RuntimeIntegration.py` updated with the scenarios above.
- Docs: `CONTRIBUTING.md` (rule, test table), `ARCHITECTURE.md` (control path, rates, fault handling, files, design decisions), `USER-GUIDE.md` (status, warnings, sync lock), `STATUS.md`.

## Trade-offs to scrutinize

1. **No self-restart.** Removing it means the earlier incident ("persistent bad object after a reboot until the service was restarted") now shows the error in status. Recovery is then manual, using the panel's **Restart audio service** button or menu command. Rationale: in that case audio was already off, a process restart cannot repair `coreaudiod`, and the watchdog's real effect was to kill working audio. A middle ground would be `exit(1)` only while the engine is stopped, letting launchd throttle. It was not chosen, because it reintroduces a threshold policy and could loop against a broken `coreaudiod`.
2. **Sync lock while running.** Previously an external rate change on a locked secondary fired an engine listener, silenced everything and rebuilt. Now `maintain()` finds a connected locked secondary at another rate than the engine and calls `SPSetHardwareRate` without stopping. Unlocked interfaces are still never changed. It tries once per observed mismatch (`lockAttempt`, reset by a rebuild or when the mismatch clears), so a refusing device is not hammered every heartbeat; the refusal stays in status. A master rate change still needs a rebuild, because the virtual format changes, and locked members follow inside it.
3. **A failed rebuild restores the previous configuration when the hardware still matches it.** This was changed after the reviewer's second round; see below. Preset identity switches are excluded, because the old endpoint has already been withdrawn.
4. **A secondary left out at start is not retried automatically.** It is retried at the next rebuild, at reconnect, or through **Restart Audio Service** in the StudioPatch menu.
5. **`stale()` polls HAL every heartbeat**, now only stream layout and buffer size. Latency and safety offsets are republished through `SPPublishLatency` instead. False positives should still be checked on the real UFX/ZED.
6. **Dead code left in place:** `SPFollowMaster` and `ratePlan`/`applyRates` (only `rate-tests` and the fake use them), and the driver's non-direct bridge/ring path. All are candidates for a separate cleanup.

## Verification

- `ctest`: 10/10 suites passed. The Swift suites must be built outside sandboxes that block SwiftUI macros; they were rebuilt and run that way.
- `Scripts/test-runtime.sh`: every scenario passed, including the new ones.
- The real `StudioPatchService` sources linked against `libpatchbridge.a` (unsigned link check only).
- **Not done:** no `Scripts/build.sh`/`Dist` rebuild, no installation, no service restart, no hardware run. The service change needs a signed build and a service restart. The driver change needs a driver install and a Mac restart.

## Suggested checks for the reviewer

- Grep for `stopEngine()`, `AudioWorker.stop` and `engine.reset()`. They should appear only in `withdrawIfDisconnected`, `rebuild` and `SPStop`.
- Confirm no remaining throw in `DirectEngine::start` can be caused by a single secondary, route or channel.
- On hardware:
  - Switch 48↔96 kHz with routes on channels that disappear at double speed.
  - Request an unsupported rate from Ableton with a locked secondary.
  - Change the buffer size or settings in the interface's control panel while routing.
  - Change a locked secondary's rate on the device itself while routing. It should be set back without interrupting other interfaces, or be reported if it refuses.
  - Unplug and replug the secondary and the Sync Source.
  - Make the session file unreadable while routing.
  - Watch `stale()` for spurious rebuilds over a long session.
- The audit's `work/audio-stop-audit/` fixtures exercise the old behavior and are expected to diverge now.

## Second review round

The reviewer of this hand-over found seven further problems. All were accepted and fixed in the same commit.

| Finding | Change | Test |
|---|---|---|
| P1: `rebuild()` stopped audio before the rate attempt and HAL configuration; a failure left audio off. | `rebuild()` keeps the working configuration. If applying fails and the Sync Source still runs at the previous configuration's rate (`reachedRate`), it starts the previous configuration again (`restore`). It records the change as rejected (`rejectedRuntime`): shown in status and notified once, not retried until the desired configuration or hardware changes, or the service is restarted. Preset identity switches are excluded. | Runtime: a failure before any change, and a driver-rejected configuration; both keep audio running with one stop/start and no loop. |
| P1: a failed acknowledgement caused a rebuild loop. | `handledRequest` marks a request that was applied or refused. Later heartbeats only retry `SPAcknowledgeRate`. | Runtime: `ack-fail`. |
| P1: a failed rate query fell back to (possibly outdated) inventory and could change the rate. | Without fresh rate information the current rate stays in effect. | Runtime: `bad-object` with an outdated `inventory-rate`. |
| P1: a lookup failure for a locked secondary aborted `SPSetHardwareRate`; the running-state error vanished after one heartbeat. | The secondary lookup is inside the warning path, an unreadable Sync Source rate becomes a warning, and `followSyncSource` stores errors in the persistent `rateWarnings`. | Runtime: `rate-error` during sync lock (bridge part not covered without HAL). |
| P1: unreadable latency metadata blocked the start. | `openDevice` treats unreadable alive/transport flags, buffer size, stream format, safety offsets and latency as unknown. Only a successful read showing an unusable device rejects it. Unknown timing is reported. The Sync Source safety read in `start` has the same treatment. | Needs real HAL; not covered. |
| P1 (hardware risk): `stale()` compared latency read before I/O start, so it could loop. | `stale()` compares only stream layout and buffer size. `SPPublishLatency` republishes latency/safety offsets from `maintain()`, sending only on change. | Needs real HAL; the loop source was removed. |
| P2: toggling sync lock rebuilt the engine. | `graphOf` removes `syncLocked` and the legacy `followMaster` default, so toggling is a routing-level update. | Direct: graph comparison. |

The reviewer also noted that the install script still lets launchd restart the service after an unsuccessful exit. That is intended and unchanged; the wording above now says "StudioPatch never restarts itself" instead of "no automatic restart".

Remaining limits: the bridge-level lookup fix and the metadata tolerance are covered only by code review, because the fakes do not reach the real bridge. Secondary alignment offsets (from safety offsets) are refreshed only at the next rebuild. A rejected change needs a new edit or **Restart Audio Service** to be retried.

