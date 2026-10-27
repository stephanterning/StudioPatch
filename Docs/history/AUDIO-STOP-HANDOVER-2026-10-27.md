# StudioPatch audio stop review handover

Review date: 2026-10-27. Reviewed commit: `f8b64d0` (`Keep connected audio running through non-audio failures`). Recipient: the agent implementing the audio-stop fixes. This follows the [Second review round](AUDIO-STOP-REVIEW-2026-10-26.md#second-review-round).

Five findings remain. The ordinary test suites pass, but they do not establish that connected, working audio survives every control failure. Findings 1, 2 and 5 were reproduced in isolated fixtures; finding 3 is a conditional rebuild-loop risk demonstrated at the native comparison level; finding 4 is a static exception trace only. None establishes an observed failure on the real UFX III/ZED-R16 setup.

The owner's rule remains: only confirmed physical disconnection of a preset interface, or an applied configuration change requiring a rebuild, may stop running audio. Helpful sync automation may try and report failures. Missing information must not be treated as proof of a change or success. This handover does not authorize installation, service restarts or pushing changes.

## Evidence and reproduction package

The [supporting fixtures](audio-stop-review-2026-10-27/) are preserved with this record so reproduction does not depend on temporary files from the review. Run from the repository root:

```sh
bash Docs/history/audio-stop-review-2026-10-27/run.sh
```

Requirements: macOS, the Xcode command-line tools and Python 3. The runner prints a fresh temporary build directory and writes `native-results.txt`, `runtime-results.txt` and `runtime-results.json` there. It builds against the **current checkout**; the observed results below describe `f8b64d0`. It does not check out or modify revisions. Assertions deliberately describe the reviewed defects and will need changing once those defects are fixed; this is a reproduction package, not a permanent regression suite or part of CTest.

- `RuntimeFake.cpp` is the reviewed fake backend plus one injection: `configure-unavailable` makes every `SPConfigure` call fail before changing configuration, including restoration calls. The real Swift service/controller sources are compiled against it. The runner rejects the binary if it imports any HAL query/listener/device entry points. Each process uses its own `STUDIOPATCH_TEST_DIRECTORY` and is terminated after its case.
- `NativeReview.mm` includes the real `Sources/Bridge.mm`. HAL property reads, size queries and writes are replaced by deterministic functions in the fixture. It calls the real `SPSetHardwareRate`, `openDevice`, `stale` and graph-comparison code. It does **not** call the full `DirectEngine::start`, create an audio IOProc, start a hardware device, create an aggregate or connect to the broker.
- [Recorded runtime results](audio-stop-review-2026-10-27/runtime-results.json) are the original review observations. Retry counters depend on scheduling; assertions focus on the resulting state.

The native fixture uses a no-op property setter returning success. In the buffer case it deliberately models a request that has not become the reported actual buffer size. This establishes behavior for that input sequence, not that a particular physical driver behaves that way.

## Finding 1  Restoration still depends on the failed control connection

**Priority P1. Reproduced in the real controller with a fake backend.**

Locations at `f8b64d0`: [RuntimeController.swift](../../Sources/RuntimeController.swift), `apply` lines 258–272, restoration guard lines 253–254, and `restore` lines 291–297. The real [Bridge.mm](../../Sources/Bridge.mm) calls `authorizeWrites()` at the start of `SPConfigure`, before submitting the HAL change.

`apply` stops the working engine before `SPConfigure`. If a shared dependency such as the broker/control connection is unavailable, configuring the requested state fails and configuring the previous state fails for the same reason. The old engine has already been destroyed. The new restoration path covers rejection of a particular configuration but does not cover general inability to issue configuration commands.

Reproduce with the runner's `broker-failure-before-change` case:

1. Start a two-input/two-output fake configuration at 96000 Hz and wait for `running=true`.
2. Create the `configure-unavailable` marker. It rejects all configuration requests without changing hardware rate or driver configuration.
3. Change only the desired output count from 2 to 3.
4. Wait for `Audio is off · Simulated broker unavailable`, then check that `running` remains false and the fake endpoint's `availability` file is still `1`.

Observed: one successful initial start, one stop, no successful replacement start, and a selectable endpoint. No hardware change or disconnection was injected. The fixture simulates the control failure; it does not actually restart or disconnect a broker.

Required correction: a failure that can be discovered while the old engine remains usable must not first destroy that engine. Merely calling the same failing configuration operation a second time is insufficient. Preserve the old running state until the change can actually be applied, with appropriate coverage for general control failures as well as configuration-specific rejection. Do not add a watchdog or retry supervisor.

## Finding 2  An unreadable master rate becomes a fabricated actual rate

**Priority P1. Reproduced in the real bridge with simulated HAL reads.**

Location: [Bridge.mm](../../Sources/Bridge.mm), `SPSetHardwareRate`, lines 568–579.

After `follow(master, target)`, `rate` is initialized to `target`. If reading the master's actual nominal rate fails, that target is returned in the `rate` field anyway. The controller treats it as the reached hardware rate and uses it for the virtual configuration. Locked secondaries can also be steered using this unconfirmed value.

Reproduce with the native fixture's final case:

1. Model the master at 96000 Hz and request 48000 Hz.
2. Make nominal-rate reads for the master return `kAudioHardwareBadObjectError` both inside `follow` and in the subsequent readback.
3. Call the real `SPSetHardwareRate`.

Observed: the function returns `rate=48000` with warnings and no top-level error. The master has not changed: the first failed read prevents `follow` from even submitting a rate write. The fixture directly verifies the wrong bridge response; the subsequent incorrect engine configuration is traced through `RuntimeController.apply`, not acoustically measured.

Required correction: distinguish a requested rate from a confirmed actual rate. An unreadable result must preserve known working state or remain explicitly unknown, rather than reporting the request as accomplished. Warnings do not make the fabricated `rate` field safe to consume.

## Finding 3  An assumed buffer size can still make every graph stale

**Priority P1 if the triggering sequence occurs. Conditional risk, with the native comparison reproduced. Not demonstrated on UFX/ZED and not an end-to-end rebuild-loop test.**

Locations: [DirectEngine.hpp](../../Sources/DirectEngine.hpp), `openDevice` lines 268–270 and `stale` lines 66–72; [RuntimeController.swift](../../Sources/RuntimeController.swift), handling of `status.stale` in `update`.

When the opening buffer-size read fails, `d->buffer` is set to the requested size. A later successful read is compared against that assumed value as though it were an earlier measurement. Thus a newly learned actual value can be mistaken for a change that requires rebuilding.

Reproduce in the native fixture:

1. Request 32 frames while the simulated actual buffer remains 64.
2. Fail the buffer-size read during `openDevice`; the stored value becomes 32.
3. Allow the next read in `stale()` to return the unchanged actual value 64.
4. Destroy the device description and repeat this opening/read sequence three times.

Observed: `stale()` returns true in all three cycles without an actual buffer change. If the same sequence recurs on every real rebuild, the controller will repeatedly stop/rebuild. A single transient read failure may cause only one unnecessary rebuild; the loop requires recurrence.

The previous **latency-only** loop source is fixed: the same fixture verifies that changing only latency between opening and running leaves `stale()` false three times. Required correction for this remaining case: represent an unknown buffer baseline as unknown; the first successful observation must not itself prove that hardware changed. Adding a threshold or delay would not correct that distinction.

## Finding 4  Timing confirmation can still abort the whole start

**Priority P1. Static code trace only. No executed fault-injection reproduction in this package.**

Location: [DirectEngine.hpp](../../Sources/DirectEngine.hpp), `timingApplied` and its loop, lines 336–346.

The initial `publishLatency()` has a catch that turns failures into warnings. The following `timingApplied()` lambda calls `pluginID()` outside that catch. If plug-in discovery fails after publication succeeded, the exception escapes `DirectEngine::start`. `SPStart` returns failure and destroys the prospective engine before hardware I/O is started. A timeout is nonfatal, but this exception is still fatal.

Proposed reproduction for a future bridge/start fixture, **not performed during this review**:

1. Supply valid configuration and transport setup and make the initial latency publication succeed.
2. At the following `timingApplied` lookup, fail plug-in bundle translation and the fallback plug-in-list lookup so `pluginID()` throws.
3. Assert that the current implementation returns a start error before reaching `AudioDeviceCreateIOProcID`/`AudioDeviceStart`.
4. After correction, assert that the same optional timing-confirmation failure is reported while I/O startup proceeds.

This can be tested with injected HAL/transport dependencies; inducing a real Core Audio failure on the user's workstation is unnecessary. Required correction: contain the exception across the entire optional timing-report/confirmation operation, not only its first write.

## Finding 5  Restored audio and reported frequency disagree

**Priority P2. Reproduced in the real controller with a fake backend.**

Locations: [RuntimeController.swift](../../Sources/RuntimeController.swift), `restore` lines 291–302; `pendingPanelRate` application in `update` lines 161–163; runtime snapshot publication uses `preset.sampleRate`.

Restoration sets `appliedRuntime` and `running` but leaves the desired rate in `preset.sampleRate` and the pending panel request. Consequently, the next ticks can continue publishing the rejected rate despite successful restoration of the old engine.

Reproduce with the runner's `rate-after-restore` case:

1. Start at 96000 Hz.
2. Enable the existing `rate-error` injection, which fails rate control before changing the fake hardware.
3. Change the panel/session rate to 48000 Hz.
4. Wait for `running=true` and `The previous configuration remains active`, then wait another two seconds.

Observed: one stop and one replacement start, restoration of the 96000 Hz configuration, hardware inventory still reporting 96000 Hz, but the runtime snapshot's `rate` remains 48000. The fixture's `actual_running_rate=96000` result describes the fake hardware and restored configuration; it is not an acoustic measurement.

Required correction: keep desired and effective configuration separate. Report the frequency of the running configuration after restoration while retaining the rejected request only for status and explicit retry semantics. The same distinction matters to labels and sync-follow decisions, which currently use `preset`.

## Verified fixes and scope of the passing tests

The review reran the build and all 10 CTest suites successfully. The standard runtime script passed its 22 scenario reports plus the HAL-import isolation check, 23 checks in total. Those results coexist with the additional findings above.

The native fixture also positively verifies four fixes against the real bridge/engine code: a secondary UID lookup failure becomes a warning; unreadable latency does not prevent `openDevice`; latency-only changes do not make a graph stale; and sync lock toggling leaves the graph equivalent. These checks are meaningful without physical HAL devices. They do not validate the full hardware lifecycle, real-time performance or audible delivery on UFX/ZED.

The application no longer deliberately restarts itself; launchd's existing crash restart behavior is intentional and is not a remaining finding. No new clock-quality mute or watchdog is requested by this review. Product code, installed binaries, the running audio service and physical device configuration were not changed while preparing this handover.

## Resolution

Implemented on 2026-10-27 as an amendment to the same commit. It replaces `f8b64d0`, and the new hash is in `git log`. Nothing was installed, the real audio service was not restarted, and nothing was pushed.

Baseline: before any change, the runner in this package was run against `f8b64d0`. It reproduced findings 1, 2, 3 and 5 exactly as recorded above. Finding 4 had no executable reproduction.

| Finding | Correction | Verification |
|---|---|---|
| 1. Restoration depends on the failed control connection | New `SPPrepareChange` runs **before** a running engine is stopped. It checks request validity, `authorizeWrites()` (broker), the plug-in and its configuration control, and the Sync Source. On failure the engine keeps running, the status says "Requested change not yet applied … The current configuration remains active", and the change is attempted again on the existing retry schedule. Nothing is stopped by the attempt. No new watchdog or supervisor; the restore path for configuration-specific rejection is unchanged. | Runtime: `configure-unavailable`. No stop and no start while it is set, the endpoint stays available, and the change applies after it clears. |
| 2. Unreadable master rate becomes a fabricated rate | `SPSetHardwareRate` returns `rate` only after a successful readback. Otherwise it returns warnings only and does not steer locked members. The controller treats a missing rate as a failed change. A running engine is then restored to the previous configuration; with no previous configuration, the normal retry applies. | `bridge-fault-tests`: no `rate`, warnings, and zero rate writes. Runtime: `master-rate-unreadable` restores the previous configuration and reports its rate. |
| 3. Assumed buffer size makes graphs stale | `DeviceIO::observedBuffer` is 0 when the size could not be read at start. `stale()` records the first successful read as the baseline and reports staleness only for a later difference. Padding still uses the requested size in that case, and a warning says so. | `bridge-fault-tests`: three open cycles with a failed read stay not-stale, and a later real change (64→128) is stale. |
| 4. Timing confirmation can abort the start | Publication and confirmation moved into `DirectEngine::reportTiming()`. One catch covers the whole optional step, including `pluginID()` inside the confirmation. | `bridge-fault-tests`: plug-in lookup failing at publication, and failing only at confirmation after a successful publication. Both give one warning and no exception. A mutation that catches only the publication makes the test abort with the uncaught `HALError`. |
| 5. Restored audio and reported rate disagree | `effective` (decoded from `appliedRuntime`) and `effectiveRate` describe what runs. The runtime snapshot rate, channel names (`publishChannelNames`) and sync lock (`lockMismatch`) use them. `preset` stays the desired configuration for comparison and the rejection status. | Runtime: after restoration, `rate` stays at the running rate, not the rejected one. |

Results: all 11 CTest suites passed. The Swift suites were built outside the sandbox because of SwiftUI macros. `Scripts/test-runtime.sh` passed 24 scenarios plus the HAL import check. The new scenarios cover findings 1, 2 and 5; `bridge-fault-tests` covers 2, 3 and 4.

This package's fixtures assert the **defects** of `f8b64d0`. They are expected to fail against the corrected checkout. `RuntimeFake.cpp` here also lacks the new `SPPrepareChange` symbol, so the runtime part no longer links. They are kept unchanged as the historical reproduction. Regression coverage now lives in `Tests/BridgeFaultTests.mm` and `Tests/RuntimeIntegration.py`.

Remaining uncertainties:

- `SPPrepareChange` narrows the window but cannot close it. The broker or plug-in can fail between the check and `SPConfigure`. Restoration then depends on the same dependency, so audio stays off and the rebuild retries. Keeping the old engine through a configuration change would require reusing its transport session, which the design deliberately forbids (`claimed`, fresh generation).
- With an unreadable Sync Source rate, restoration assumes the rate did not change. That holds when the first read failed, because nothing was written. If a write succeeded but every readback failed, the restored configuration may run at the wrong rate until a readable rate query triggers a rebuild at the actual rate.
- With an unknown buffer size, the timing margin uses the requested size. If the real buffer is larger, playback can underrun until the next rebuild, for example through any configuration change or **Restart Audio Service**. A warning names the interface.
- Secondary alignment offsets that come from safety offsets still refresh only at a rebuild.
- `reportTiming()` and the HAL-level behavior are covered with simulated HAL reads, not real Core Audio. None of this has been exercised on the UFX III/ZED-R16 setup.

