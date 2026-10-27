# Audio change implementation and review handover

Latest: [simplification round](#simplification-round), which removes automatic rollback and replaces several earlier mechanisms. Earlier sections below retain their original revision-specific evidence and describe behavior that no longer exists where the simplification round says so.

The original record below describes `3d6a847`. The [follow-up review](#follow-up-review-of-3d6a847) at the end supersedes its preset-publication, rate-rejection, polling, and variable-block behavior.

Date: 2026-10-27. Base: `74cef6e` (`Keep connected audio running through non-audio failures`). The working tree was clean when implementation started, so there was no pre-existing work to commit. These changes form a new commit; the base was not amended.

The owner authorized implementation followed by another agent's review. Nothing was pushed, installed or signed with the project's signing identity. The installed service, panel, driver and broker were not replaced or restarted. No real interface settings were changed. Review this diff against `74cef6e`, not against the earlier amended commit IDs.

## Why another change was needed

The five original findings and their first resolution remain in [AUDIO-STOP-HANDOVER-2026-10-27.md](AUDIO-STOP-HANDOVER-2026-10-27.md). Review of `74cef6e` found three material follow-ups:

1. **Control failure after preflight (P1, reproduced with fake backend).** `SPPrepareChange` could succeed, then `SPConfigure` fail. The controller had already stopped the engine. Restoration used the same failed control dependency. Preflight narrowed the window but did not fix the order of operations.
2. **Successful rate write followed by failed readback (P1, reproduced in simulated HAL and the controller).** A write could set the hardware to 48000 while the old engine was at 96000. Missing readback was interpreted as permission to restore 96000. Even later fresh 48000 readings could be bypassed by the rejected-configuration fast path. This was not guaranteed to self-correct as the earlier handover suggested.
3. **Unknown buffer leaves an undersized margin (conditional P1 risk).** Learning 64 as the baseline after falling back to requested 32 avoided a rebuild loop but left transport padding at 32. Under a simulated callback schedule, only half the 64-frame playback block arrived. That sample loss was reproduced in the native fixture; occurrence on UFX III/ZED-R16 was not established.

The previous fixes for optional timing confirmation and effective running-state reporting were retained. Their earlier findings were valid; they did not need another automatic stop rule.

## Implementation

### Keep the engine until the real change is applied

`Sources/RuntimeController.swift` no longer stops the engine to probe whether a configuration command will work. `SPPrepareChange` was removed from `Sources/Bridge.h` and `Sources/Bridge.mm`.

`SPConfigure` submits the actual request with the old engine still running. `ConfigurationChange` remembers the pending wire configuration and original transport generation. Subsequent calls confirm the same request, without resubmitting after a failed read or broker claim. HAL readiness at the old generation means rejection; a new generation with matching configuration means the change was applied. The same-format case also requires a new generation, preserving the existing fresh-session/claimed rule.

The Swift pending record preserves the exact engine payload, originating rate request and panel-rate intent while that request resolves. A newer edit, including a return to the old preset, cannot strand an already accepted generation. It is processed afterwards. This record is transaction state, not a watchdog or a process-restart mechanism.

Only after confirmation does `applyConfiguration` stop the previous hardware engine and start the replacement. Ordinary HAL rejection leaves the old engine untouched. A failed control command or query reports a deferred change and uses the existing retry schedule. If the Sync Source refuses a rate and the resulting graph equals the running graph, no configuration or restart is needed.

The existing last-working-configuration behavior is preserved for **a new engine that fails to start after HAL actually applied the format**. Restoration requires a fresh successful rate query for the old Sync Source matching the old rate. It is never authorized by a missing read. A successful restoration reports the requested change as rejected once. Restoration does not recursively restore again if it itself fails.

### Unknown rates stay unknown

`SPSetHardwareRate` still returns `rate` only after successful readback. The controller now leaves its old engine running if that field is missing, including when the hardware write already succeeded. A later confirmed rate drives the appropriate configuration; it does not restore a guessed rate. Running-rate comparisons use `effectiveRate`. A fresh rate different from the rejected request can invalidate the rejection, but merely rereading the same rejected rate must not create a retry loop.

### Use the callback's actual block length

`DirectEngine::observeBlock` establishes the margin from the Sync Source's actual callback block before copying samples. Startup still tolerates an unreadable buffer property; the first usable callback corrects the provisional value. Later block-length changes update it directly. `stale()` now compares channel layouts only. Latency and safety-offset metadata continue to be republished without rebuilding.

The existing full-block padding policy and explicit measurement override remain. No new mute, clock-quality gate, threshold, debounce or restart supervisor was introduced.

`actualBuffer` and shared input/output padding are atomic because callbacks now write them while status, secondary callbacks and the virtual driver read them. `SharedTransport::Magic` changed from `0x5350444952454358` to `0x5350444952454359`. **Driver, broker and service must be built and eventually installed together.** No installation is authorized by this handover.

### Physical withdrawal while HAL is pending

`PatchPlugin::setAvailable(false)` can withdraw a device even while a configuration is pending. Publication still waits for configuration readiness. The bridge clears its pending request on successful withdrawal; a late HAL completion does not add the withdrawn endpoint back. This implements the owner's explicit physical-disconnection exception.

## Verification and reproduction

Run from the repository root on macOS with Xcode tools:

```sh
cmake --build build -j4
ctest --test-dir build --output-on-failure
bash Scripts/test-runtime.sh
```

SwiftUI macro expansion needs an unsandboxed compiler invocation in this environment. Compilation only writes local build artifacts. Do not use the install scripts or start the production binaries to reproduce these cases.

The old `Docs/history/audio-stop-review-2026-10-27/` package is unchanged. Its assertions intentionally describe older defects and are not current regression expectations. Use the maintained tests below.

| Case | How it is exercised | Verified result and limit |
|---|---|---|
| Control failure after authorization | `bridge-fault-tests`: allow controller authorization, fail the actual configuration property write. Runtime suite: `configure-unavailable` while changing output count. | Native request keeps its original generation and no pending submission. Runtime start/stop counters and publication stay unchanged. The real broker is not disrupted. |
| Slow HAL, rejection and readback/claim errors | Native test holds readiness false, then rejects or applies a new generation; injects failed config read and post-commit claim. Runtime test uses `configure-pending` and `configure-confirmation-fail`, then edits back to the running preset. | Native submission count stays one per request, including same-format requests. Runtime preserves the old engine while pending, resolves the accepted request, then applies the newer preset. No generation is abandoned. |
| Rate write succeeds, readback fails | Native test changes simulated master 96000→48000 and fails readback. Runtime `write-then-unreadable` does the same before the next fresh rate read. | Native result has no fabricated `rate` and does not steer the secondary. Runtime performs no immediate stop/restore, subsequently starts 48000 once, and stays there. No acoustic hardware measurement. |
| Unknown/changing block size | Native test fails the initial buffer query for requested 32, supplies actual callback blocks of 64 then 128, three blocks each, and writes known playback/input samples. | Every routed playback sample and captured sample is checked; unused output stays zero. Both margins follow the real block length. Separate `stale()` checks show buffer and latency metadata alone do not rebuild. The HAL callback schedule is simulated. |
| Refused rate leaves graph unchanged | Runtime `master-refuses` while the requested rate differs from the running rate. | Request is acknowledged and warned about with unchanged engine start/stop counts. |
| Applied change cannot start | Runtime `start-reject` rejects the new output-count graph but allows the previous one, with a freshly readable unchanged Sync Source rate. | Previous graph starts once; the failed requested graph is not retried in a loop. |
| Physical removal during pending change | `core-tests` holds HAL callbacks, checks actual samples through the old handlers, withdraws the endpoint, then executes the delayed callbacks. Runtime test disconnects while `configure-pending` is set. | Old samples work before withdrawal. The endpoint is absent after withdrawal and stays absent after late HAL completion; runtime reconnect starts it again. Core test uses in-process driver objects, not the installed plug-in. |
| Existing timing-confirmation fix | Native fault test fails plug-in lookup before and after timing publication. | Optional confirmation remains a warning. No hardware IOProc is started by this fixture. |

Final verification: **11/11 CTest suites passed; 28/28 runtime scenarios plus the HAL-import isolation check passed (29 checks total).** The final driver and broker targets built, and the production service and panel linked to the real bridge into `build/review-StudioPatchService` and `build/review-StudioPatch`. They were not launched, packaged, installed or signed with the project identity. SwiftUI compilation was run outside the sandbox after the sandbox blocked Xcode's macro server.

The runtime log for this local run is `build/audio-change-runtime-final.log` (ignored build output, not a portable evidence artifact). The maintained test sources above contain the reproducible assertions. Initial test development caught a fixture using the driver's default 18 channels where it expected two, and a notification-file timing race; the fixture now configures two channels explicitly and waits for the notification contents. Those were test-fixture corrections, not relaxed audio expectations.

## What still needs scrutiny

- **Applied changes are not seamless.** HAL can replace the virtual session before the service observes the new generation and starts its hardware graph. The pending operation is checked on the service heartbeat (normally one second); failed confirmation or broker acquisition can extend this interval. The old engine's `running` flag is not proof that the new virtual session already carries samples. This is the applied-configuration boundary, not a control-error-triggered stop of the old engine before any change.
- **No transactional HAL guarantee is claimed.** A rate can change physically before readback succeeds, and a committed format/start or its restoration can fail. The code preserves old routing before commit, refuses to invent a rate, and reports failures. Review whether the commit/confirmation boundary and the constrained restoration cover the intended policy; do not equate a fake backend's `running=true` with acoustic continuity.
- **Pending operations and later edits deserve particular review.** Inspect the interaction of `ConfigurationChange`, `pendingConfiguration`, failed acknowledgement and confirmed disconnection. A host request that never completes is not timed out by a new supervisor.
- **Actual layout changes still rebuild.** Buffer and latency reads can no longer create the old comparison loop. Repeated real layout changes, or a driver that falsely reports changing layouts, are not masked by a threshold. There is no long-duration real-HAL qualification here.
- **Live padding changes alter latency.** The sample test proves the particular unknown-buffer/block-change sequence. It does not establish glitch-free transitions under all DAW scheduling, CPU load or device timing. Latency metadata is republished on the control tick; secondary alignment offsets still refresh at rebuild. Existing physical 32-frame latency measurements do not qualify arbitrary block transitions.
- **No UFX III/ZED-R16 or Ableton execution was performed.** A matching signed package and explicit owner approval are required before later installation or hardware tests. Do not restart Core Audio, the broker or the real audio service during this review.

Please review the new commit against `74cef6e`, focusing on the owner's design rule and the cases above. Report concrete defects and distinguish simulated evidence from a hardware risk. Do not push or install anything.

## Follow-up review of `3d6a847`

Date: 2026-10-27. The owner supplied the second agent's review and authorized fixes. This is a separate follow-up commit on top of `3d6a847`; the initial working tree was clean. No installed component or physical interface was changed, and no real service, broker or Core Audio process was restarted. Nothing was pushed.

### Findings and disposition

| Review finding | Disposition | Evidence |
|---|---|---|
| 1. New preset published before its clock; missing notifications | Fixed. The driver withdraws the old identity **at configuration commit**, and does not publish the new one. The service reports the named withdrawal and later publishes only through the existing clock-confirming `SPSetDeviceAvailable` path. A failed control command before commit leaves the old identity/audio alone. | In-process driver tests check absence before explicit publication. Runtime tests check ordered withdrawal/stop/start/publication, named notifications, a control failure before commit, and a simulated unavailable clock after start. |
| 2. HAL rejection after a successful rate write leaves old graph at the wrong rate | Fixed for a successfully reversible write. The bridge separately returns the previous rate and the successful write target; these are **not** a confirmed actual-rate result. On rejection the controller tries once to undo its own write, only if the running graph is still the recorded previous graph and a fresh hardware read matches the write target. Locked members follow the source after restoration. | Permanent runtime scenario first uses **only the master**, then repeats with a locked secondary. It asserts actual hardware rate, running rate, unchanged engine start/stop counts, and no configuration resubmission. A separate scenario verifies a refused undo: warning persists, audio is not stopped and there is no configuration retry loop. |
| 3. Confirmation waits for a one-second heartbeat | Fixed scheduling. A successful pending response schedules one 25 ms follow-up. It confirms the existing request; it does not submit another one. Errors retain the ordinary retry schedule. There is no deadline, watchdog or forced restart. | Simulated HAL completes after 100 ms. The test requires completion processing within 750 ms, distinguishing it from the previous one-second polling. This is not an upper-bound guarantee for real HAL calls. |
| 4. Rate writes occur while StudioPatch I/O runs | Retained as an explicit hardware risk. Stopping first would reintroduce silence from a refused/unconfirmed change. A control-access check now runs before an intentional rate write, but it cannot close all races or make every hardware driver accept a live write. | Static trace only. No UFX III/ZED-R16 live rate changes or acoustic tests were run. The assertion that every change necessarily causes audible wrong tempo is stronger than the available evidence; the transient mismatch and refusal risk are real. |
| 5. Padding shrinks/grows with variable blocks | Fixed shrinking. Input/output padding keeps the largest margin reached during an engine lifetime. Short blocks cannot advance the read position by shrinking it. A new engine resets the margin; the existing test-only override remains. | Native callback test runs 128, 32, 64, 16, 128-frame blocks with a continuous unique sample ramp and a fixed timestamp lead. Every playback sample must remain in sequence. Existing tests still cover growth from an unreadable requested 32 to actual 64/128 and capture delivery. |
| 6. Fan-out names follow inventory order | Fixed. `selectedDevices(for: effective)` resolves live/cached metadata in the running preset's interface order. | Runtime case reverses preset membership while inventory order stays fixed; the combined output label must put the secondary before the master. |

The requested removal of automatic stops is preserved: `stopEngine()` is still called only by confirmed withdrawal and after an applied configuration. No new silence latch, clock-quality test, restart rule or buffer threshold was added.

### Related details worth reviewing

- `SPPrepareChange` has returned in a narrower role: validate request syntax and authorize broker/plug-in access **before changing hardware rate**, while the current engine continues. It is not a stop precondition or a substitute for submitting the real command. A later control failure still does not destroy the old engine.
- `RateWrite` records only a successful master write that started at the effective engine rate and used the same Sync Source. It survives an unreadable immediate readback so a later HAL rejection can still identify our write. A missing actual-rate field remains unknown. The undo record is consumed once; a different or unreadable current hardware rate does not authorize a write back.
- Live sync lock now uses `followOnly`: read the source's actual rate and steer locked secondaries, without writing the master. This prevents sync lock from accidentally masking finding 2 by forcing the source back to the old graph's rate. The native bridge test specifically checks a 48 kHz source with a 96 kHz graph request: follow-only returns 48 kHz and makes zero master writes.
- The replacement endpoint is hidden in `PatchPlugin::configure`, after the driver has committed an identity change. Withdrawing it in Swift **before** the fallible configuration command would have reintroduced the original control-error failure. The existing public-device clock check is reused, not replaced by a new startup gate.
- Pending and failed confirmation messages explicitly say that a running hardware engine does not yet confirm audio through the new virtual session. This avoids treating `running=true` as acoustic proof after HAL has changed generations.
- The shared-memory layout/protocol did not change again in this follow-up. The `4359` protocol introduced in `3d6a847` still requires matching driver, broker and service relative to older installed builds.

### Reproduction and verification

Use the maintained suites, from the repository root:

```sh
cmake --build build -j4
ctest --test-dir build --output-on-failure
bash Scripts/test-runtime.sh
```

The two requested regressions are now permanent assertions in `Tests/RuntimeIntegration.py`. The native publication and variable-block checks are in `Tests/CoreTests.cpp` and `Tests/BridgeFaultTests.mm`.

Counterfactual verification used `git archive 3d6a847 Sources` into an ignored local build directory and linked the old real Swift controller to the current simulated backend. The **same maintained assertion blocks** were extracted for isolated execution:

- The old controller fails the identity test because the named withdrawal notification is missing.
- The old controller fails the master-only rate test with reported/graph rate **96000** and the fake hardware-rate file **48000**. A secondary is intentionally omitted in this first pass: the old live sync-lock implementation could otherwise set the master back and mask the defect.
- The old driver's in-process preset identity test fails the assertion that the newly configured UID is absent before explicit publication.
- The corrected controller passes both rate variants, and the corrected driver passes the absence/publication test.

Local counterfactual logs and generated runners are under `build/followup-proof/` (ignored, not portable artifacts). The original agent's `work/review-0427/` files were not modified. The maintained test sources are the reproducible record; they do not touch Core Audio devices or launch the production service.

Final verification: **11/11 CTest suites passed; 33/33 runtime scenarios plus the HAL-import isolation check passed (34 checks total).** The simulated 100 ms HAL transaction was followed to completion after **0.104522 seconds** in the final run. That number measures the fake scenario, not an acoustic interruption. The production service and panel linked against the real bridge into `build/review-followup-StudioPatchService` and `build/review-followup-StudioPatch`; they were not launched or installed. Driver and broker targets also built. SwiftUI compilation ran outside the sandbox because its macro server requires that here. The local final runtime log is `build/review-followup-runtime-final.log`.

Test-development corrections: publication reordered the test-only internal bridge and exposed endpoint, so core tests now locate the exposed endpoint by UID rather than assuming index zero. The offline-start fixture now supplies its selected secondary, since the added rate tests finish with a two-device preset. Neither correction weakens the audio/availability assertions.

### Remaining limits and hardware risks

1. **Live rate changes remain driver-dependent.** A device can reject a change while any I/O is running, and there can be a transient mismatch between the old graph and a newly written hardware rate. A failed control command after the write can extend that interval. The status identifies the written hardware target and old graph rate. These are hardware/transaction risks, not a reason to add a mute policy or pre-emptively stop working audio.
2. **Undo is best effort, not another control loop.** A refusal or failed read can leave the old engine and hardware at different rates. That is reported; the engine is not silenced. The failed-undo case is simulated. The guards against an intervening external rate change or an unreadable undo precondition were inspected in code, not exercised against real HAL. There remains a normal race between a fresh read and an external writer; no cross-driver atomic transaction is claimed.
3. **A larger block can still change latency once.** The fix removes repeated shrink/grow oscillation. It does not claim that increasing the margin is acoustically seamless, and it retains extra latency after blocks become smaller (possibly including a provisional startup margin). Latency reporting uses that retained margin; the control tick republishes it. Secondary alignment offsets are still refreshed at rebuild.
4. **An accepted HAL request can remain stuck in the driver.** No timeout/cancellation supervisor was added. Restarting only the service does not clear `configuring_` in the loaded driver and can stop the old service's otherwise running engine. Do not use a real restart as a reproduction here.
5. **After HAL commits, mapping/start can still be delayed or fail.** Faster polling reduces the ordinary waiting interval, not all silence after an applied change. Broker failures or an unavailable new mapping remain possible. Pending status now states the uncertainty. A matching physical driver/service deployment and acoustic tests are still required before any claim of real-hardware continuity.

Please review this follow-up against `3d6a847`, especially identity commit/publication, ownership and one-shot undo of rate writes, and completion polling. Report findings before changing scope. Do not install, restart the real audio service/Core Audio/broker, or push anything.

## Review of `5183ca7`

Date: 2026-10-27. Base: `5183ca7` (`Fix preset publication and undo rejected rate changes`). The owner requested implementation in a new commit, with no push. The working tree was clean at the start. No installed binaries, physical interfaces, real audio service, Core Audio or broker were changed or restarted. The reviewer's `work/review-0427/repro-5183ca7.py` was left untouched.

### Changes and decisions

1. **Bound the fast polling burst, not the HAL request.** `PendingConfiguration` retains a monotonic `followUntil` when it is created. For the first second, successful pending responses can schedule the existing 25 ms follow-up. Thereafter the one-second heartbeat continues the same outstanding request. A normal tick or another pending response does not extend the burst. There is no transaction deadline, cancellation, withdrawal, engine stop or process restart at expiry. The short burst still runs the ordinary controller path; a second acknowledgement-only control path was deliberately not added.
2. **Keep the running identity's display name.** Engine JSON deliberately excludes `virtualDeviceName`, so the service now retains `activeDeviceName` alongside the active graph and includes a name snapshot in `PendingConfiguration`. Restoration carries the previous name with the previous payload. `effectiveDeviceName` uses the desired name only when the desired and running UIDs agree; otherwise it uses the active name. Successful metadata writes and availability responses update the published-name record. This also preserves ordinary active-preset rename behavior.
3. **Use the same bounded burst for first-clock publication.** Successful `SPStart` opens a one-second publication burst. While running and unpublished, the controller retries promptly through the existing clock-checking publication operation. If the clock remains unavailable, the ordinary heartbeat takes over. Failed publication never restarts or stops the engine, and a retry does not renew the burst.
4. **Post-commit start failure: documented intentional boundary, unchanged code.** The one-shot undo of an owned rate write still applies when HAL rejects the format before commit. After HAL accepts the new format, the service consumes that write record. If the new graph cannot start, restoration is attempted only if a fresh read confirms that the old source rate still applies. If the source is already at the new rate, audio can remain off while the new graph is retried. We have not extended this into another hardware-rate reversal plus another HAL format transaction: that would be a broader rollback policy with additional failure points. This is an explicit limitation, not a claim that the owned write is technically impossible to undo. It follows an applied configuration, rather than a control-error-induced stop of an unchanged working graph.
5. **Restoration across preset identities: unchanged pending an owner decision.** A failed switch can restore and republish the previous UID while the panel still shows the desired new preset. The benefit is returning the prior working device/audio when its source rate still matches. The cost is disagreement between the selected preset and the actual active endpoint, and potential DAW reselection. Status/notifications describe restoration; the name fix ensures they identify the restored device honestly. This change does not decide whether future restoration should exclude preset switches, and does not modify that behavior.

The only new deadlines govern how often the service asks for progress. They are not audio-protection deadlines. The existing `stopEngine()` call sites remain confirmed withdrawal and replacement after an applied configuration.

### Permanent regressions and counterfactual evidence

All new cases are in `Tests/RuntimeIntegration.py`, using the real Swift controller and `Tests/RuntimeFake.cpp`. The fake backend now counts publication checks and can delay the first simulated clock by 100 ms. No HAL device is touched.

| Case | Assertion | Result against `5183ca7` |
|---|---|---|
| Never-ready configuration | After 1.5 seconds, count configure calls for another four seconds: 2–6 calls, unchanged engine start/stop counts, still published. Removing the pending marker must allow the same operation to finish later. | **Fails: 118 configure calls in the four-second measurement window.** |
| Failed preset switch restores old name | Reject the new graph's start; require old UID and old name, including its return notification. Rename the still-rejected desired preset, then disconnect: the old name must persist and identify the withdrawal. An active-UID rename after reconnect must still work without restart. | **Fails:** restored legacy UID was named `StudioPatch (Rejected B)`, the desired preset's name. The new name assertion fails before later checks. |
| First clock arrives after 100 ms | New identity must publish within 750 ms of engine start, with exactly one engine replacement. | **Fails:** publication took `0.893313` seconds in the isolated baseline run. |
| First clock never arrives | After the initial burst, 2–6 publication checks in four seconds; engine keeps running, device stays absent, no restart. Removing the marker later publishes without restarting. | Added coverage for the new publication burst; the old code already used slow publication retries. |

The baseline service was compiled from sources exported with `git archive 5183ca7 Sources`, linked to the same current fake backend. The maintained test blocks above were extracted without changing their assertions into isolated runners under `build/review-5183-proof/`. Local logs and fixtures are ignored build output; the permanent assertions are the portable evidence. This verifies controller behavior against simulation, not real HAL scheduling or acoustic continuity.

The corrected full runtime run passed all four cases. First-clock publication took `0.138193` seconds in that simulated run. This is not a worst-case bound: real property calls and scheduling can be slower. The existing 100 ms pending-configuration completion case still passes, so bounding the burst did not remove prompt normal completion.

Final verification: **11/11 CTest suites passed; 37/37 runtime scenarios plus the HAL-import isolation check passed (38 checks total).** The production service and panel linked against the real bridge into `build/review-5183-StudioPatchService` and `build/review-5183-StudioPatch`. Neither was launched, packaged, installed or signed with the project identity. SwiftUI compilation ran outside the sandbox for Xcode macro expansion. The final local integration log is `build/review-5183-runtime.log`; baseline logs and extracted maintained assertions are in `build/review-5183-proof/`.

### Remaining limits

- A request can still remain stuck inside the driver. Reducing polling cost does not repair `configuring_` or a missing mapping. Restarting the service alone does not clear driver state; no automatic restart or cancellation was added.
- The fast burst performs full controller ticks for at most its first second. Normal HAL notifications and user edits can independently cause ticks. The test constrains the service's self-scheduled pending loop under a stable simulated workload, not every possible external event rate.
- A delayed first clock can leave the replacement endpoint absent; once the burst expires, publication may wait for the next ordinary heartbeat. The engine is not stopped for lack of clock confirmation.
- Applied changes can still interrupt audio, and post-commit start failure at a changed hardware rate can leave audio off as described above. Cross-preset restoration policy remains an owner decision.
- Live hardware rate writes, retained larger padding, and actual driver/mapping timing remain hardware risks from the earlier handover. No UFX III/ZED-R16 or Ableton hardware/audio test was performed.

Please review the new commit against `5183ca7`, especially the lifetime of the polling bursts and the association of names with running/restored UIDs. Keep findings separate from hardware-only risks. Do not install anything, restart the real service/Core Audio/broker, or push.

## Simplification round

Date: 2026-10-27. Base: `f827958`. This is a new commit, not pushed. No installed binaries, physical interfaces, real audio service, Core Audio or broker were changed or restarted.

The review loop was stopped deliberately. Instead of another point fix, the owner made explicit decisions about how far automation goes, after reviewing a whole-flow assessment by both agents. This round implements those decisions and removes what they make unnecessary.

### Owner decisions

1. **No automatic rollback after an applied change.** If a change fails after Core Audio has applied it, audio is off with a clear message. The device stays published and the change is retried while audio is off. Nothing returns to the previous configuration, within or across presets.
2. **Retries while audio is off are kept.** New configuration/start attempts after a concluded failure happen only while audio is off. While audio runs, StudioPatch may keep waiting for an already submitted Core Audio request, acknowledgements, metadata, publication and the sync check.
3. **The device stays published** when an applied change leaves it without an engine, as before. No new hiding rule.
4. **A preset whose hardware is missing is withdrawn**, as before. The disconnection check keeps following the desired preset.
5. **Rate undo before commit, in simple form.** If StudioPatch wrote the Sync Source rate in the current attempt and Core Audio then rejects the change, StudioPatch sets the Sync Source and locked interfaces back once to the running engine's rate and reports the result. A rate changed by something else (for example the interface's own settings) is never set back.
6. **Sample-rate behavior:**
   - A. The Clock Source changes: StudioPatch follows, and locked interfaces follow. A locked interface that cannot follow is reported (message and notification); audio continues.
   - B. A locked interface changes elsewhere: reported as not in sync (message and notification); never set back while audio runs.
   - C. StudioPatch changes rate (DAW or panel):
     - The Clock Source refuses or cannot be confirmed: stay at the previous rate, and the DAW and the panel must show it (message and notification).
     - The Clock Source changes but a locked interface refuses: no rollback (message and notification).
     - Core Audio rejects after our Sync Source write: decision 5.
     - Success: short interruption, no notification.
7. **System notifications only for problems**, once per problem. No notification for successful changes, publication or preset switches. The status line still shows everything.

### Changes

- `RuntimeController`:
  - **Removed:** post-commit restoration (`RejectedChange`, `restoring`, the recursive `applyConfiguration`), `RateWrite` with the fresh-read ownership guard, live sync follow (`followSyncSource`, `lockAttempt`, `followOnly`), success and preset-switch notifications, and the format-notification bookkeeping (`pendingFormatNotification`, `notifiedFormatFailure`, `failureNotified`, `publishedDeviceName`).
  - **Added:** `PendingConfiguration.wroteSyncSource`, a single `notices` set for one-notification-per-problem, `refuseRate` and `syncProblem`.
- `Bridge.mm`: `SPSetHardwareRate` returns `wroteSyncSource` instead of `previousRate`/`writtenRate`, and has no `followOnly`. `SPFollowMaster` is removed, and `RateSync.hpp` now contains only `sameRate`.
- `Driver.cpp`: a client rate request (device nominal rate, or a stream format at another rate) is only forwarded to the service. The device and its streams keep reporting the running rate until a configuration replaces them. Before this change, libASPL set the requested nominal rate immediately, so a refused request left the DAW believing the new rate applied.
- `RuntimeConnection`: `notifyProblem` and `notifyDisconnected` replace the success-capable notification helpers.

### Measures (`RuntimeController.swift`)

| | `f827958` | This round |
|---|---|---|
| Lines | 466 | 405 |
| Stored properties | 29 | 25 |
| Nested state types | 3 (`RejectedChange`, `PendingConfiguration`, `RateWrite`) | 1 (`PendingConfiguration`) |
| Ways a failed change can trigger more hardware/HAL work while audio runs | restore-after-start, owned undo with read guard, live sync follow | one-time owned undo on HAL rejection |

The property count is from a mechanical scan, so treat it as indicative. The removed paths are the meaningful part.

Across `Sources/` and `Tests/` the diff is about 180 lines added and 430 removed.

### Tests

Removed together with their behavior:
- `rate-tests` (`ratePlan`/`applyRates`).
- The runtime scenarios "failed start after commit restores the previous graph", "restored preset keeps its own name", and sync lock setting a changed secondary back, plus its follow-error case.
- The `followOnly` and `previousRate`/`writtenRate` assertions in `bridge-fault-tests`.

Changed to the new behavior:
- Runtime scenarios no longer expect success or switch notifications.
- An unreadable Sync Source rate is a reported refusal; the old engine and rate stay.
- A start failure after commit: audio off, one `runtime-failure` notification, device still published, retries, and recovery when the fault clears.
- A locked interface out of sync after a refused follow gives one `sync-mismatch` notification.
- A Sync Source refusal gives one `rate-refused` notification.

Added:
- `core-tests`: after a client rate request through the device or through a stream format, the device and stream still report the running rate and the request is forwarded.
- `bridge-fault-tests`: no `wroteSyncSource` when the Sync Source already has the rate.
- Runtime: a locked interface changed elsewhere is reported once and not set back (no rate write, no restart).

Kept for remaining guarantees: control, query and metadata failures not stopping audio; the owned rate undo, including a refused undo; pending, never-ready and prompt HAL follow-up; clock-ready publication; disconnection during pending; preset-order names; and all native transport tests.

Verification: **10/10 CTest suites passed, and `Scripts/test-runtime.sh` passed 36 scenarios plus the HAL-import check (37 checks).** The Swift suites were built outside the sandbox for SwiftUI macros. The production service sources linked against the real bridge (link check only). Nothing was launched, packaged, installed or signed with the project identity.

### Acceptance criteria

1. Control, query and metadata failures do not stop running audio: covered by the kept runtime scenarios.
2. `stopEngine()` is called only by confirmed withdrawal and after an applied configuration: true, in two places in `RuntimeController`.
3. No new watchdogs, thresholds or timeouts affecting audio: none added.
4. The common path (routing, rate change from panel or DAW, preset switch) passes the runtime suite.
5. Fewer independent states and transitions: see the measures above.

### Known limitations (accepted)

- An applied change whose new engine cannot start leaves audio off until a retry succeeds or the user changes the setting. Each retry submits a new Core Audio configuration, so a DAW may see a configuration change about every five seconds while the fault persists.
- A rejected change after a rate written by something else leaves the old graph and the hardware at different rates. This is reported, not corrected.
- The owned undo is best effort and happens once. A refused undo is reported. There is a normal race with an external writer at the same moment.
- A locked interface changed elsewhere stays out of sync until the user fixes it, StudioPatch next changes rate, or audio starts again.
- An accepted Core Audio request that never completes still blocks later changes. Audio keeps running; no timeout was added.

### Hardware risks (not tested)

- How Ableton reacts when its rate request is only forwarded and the device reports the new rate a moment later (on success) or keeps the old one (on refusal). This must be checked on the real setup.
- Live rate writes while StudioPatch's own I/O runs, margin growth and real driver/mapping timing, as described in earlier sections.
- Nothing in this round was run on UFX III/ZED-R16 or in Ableton. The driver change requires installing the driver and restarting the Mac, together with the matching service and broker (`4359` protocol).

### Review follow-up of `b7c1c21`

The review found two deviations from the owner decisions. Both are fixed.

1. **An own Sync Source write was lost after an unreadable readback.** The write was reported as a refusal; on the next heartbeat the confirmed rate looked external, so a HAL rejection of that attempt did not undo it. The controller now keeps `ownSyncWrite` (the rate it wrote while audio ran) until the change is applied, rejected, the rate is no longer needed, or the hardware is withdrawn. A rejection then undoes it once, as in decision 5.
2. **A locked interface changed elsewhere was set back by an unrelated change.** Every rebuild called `SPSetHardwareRate`, which always steers locked members to the Sync Source. `rebuild` now sets hardware rates only when the target rate differs from the running rate, the Sync Source rate changed, or audio starts. A channel-count or routing change no longer touches hardware rates. Starting audio still steers locked interfaces, because that is part of establishing the graph.

Tests: two runtime scenarios were added, one per finding. The "hot unplug while a change is pending" scenario now includes a rate change, because its simulated failure is in rate control, which a channel-count change no longer calls. The first new scenario fails against `b7c1c21` (the hardware stays at 48000 Hz). **10/10 CTest suites and 38 runtime scenarios plus the HAL-import check (39 checks) passed.**

