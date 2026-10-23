# Latency improvement plan and handoff

Updated: 2026-10-23. Current user requirement: at most 1 ms added round trip over the selected Sync Source, accurate directional reporting, and no significant stability regression. The later stability constraint supersedes the earlier instruction to defer stability work. Version 0.1.1 reporting is implemented, installed and physically checked at 48/96 kHz and 32/64-frame engine buffers. See [measurement results](LATENCY-MEASUREMENT-2026-10-23.md) for accuracy limits and remaining DAW/stability work.

## Current performance target — clarified after reporting verification

The user requires approximately **at most 1 ms EXTRA round-trip latency over the selected Sync Source interface used directly**. This is not a 1 ms total-latency target and not 1 ms per direction. At 96 kHz the added budget is 96 frames for input + output together.

Compare the same physical path, sample rate, actual client buffer, signal/measurement method and driver error compensation. Preserve correct HAL reporting throughout optimization. Do not compare device-property totals alone when direct and virtual devices have different safety offsets: the end-to-end comparison must account for client scheduling consistently.

The user's Ableton screenshots show 96 kHz / 256 samples / 5 samples error compensation: direct UFX III 6.93 ms overall versus StudioPatch 19.2 ms, approximately 12.27 ms extra. The corresponding target for that comparison is approximately 7.93 ms overall or less. Screenshots are reported latency, not a new physical measurement.

Read-only runtime inspection after the screenshots confirms that the StudioPatch engine is already at 32-frame I/O and 64-frame transport margin, with UFX as Sync Source and ZED selected. Aggregate timestamp gap remains 546 frames (input safety 323, output safety 159). Reducing Ableton's 256-frame buffer is not the solution to a same-buffer overhead requirement. Investigate bypassing the hidden bridge/aggregate scheduling overhead on the Sync Source path; retain other interface routing and measure the same reference path with those devices selected. A direct shared-memory candidate has now measured 64 added frames (0.667 ms) at 96 kHz / 256 client frames. The latest implementation and acceptance evidence are recorded in `LATENCY-DIRECT-2026-10-23.md`; intermediate candidates with missing input frames were rejected.

## Primary objective — accurate latency reporting

Report the selected Sync Source interface + StudioPatch latency independently for input and output. The user explicitly selected Sync Source as the reporting reference even when other interfaces are routed; with UFX III selected, ZED must not replace that reference with its own reported latency. Other interfaces may have different actual path latency. Keep the interface's reported latency, any independently measured interface error, and StudioPatch's added delay separate. Do not assume equal input/output delays or divide a measured round trip by two.

The user connected UFX III analog output 3 to analog input 3 by TRS, confirmed TotalMix Software Playback 3 feeds output 3 without feedback, and confirmed isolation from speakers/headphones. Low-level test playback on this path is authorized. Current preset already maps virtual channel 3 to this physical channel in both directions.

Work order (supersedes the numbered historical stages below):

1. Capture direct UFX loopback with raw samples and input/output host timestamps; compare the timestamp-referenced path delay with device + stream latency. Record client buffer and safety offset separately, without double counting scheduling already included in timestamps.
2. Capture the identical physical route via StudioPatch, with simultaneous direct UFX input observation. Use matched sample provenance and timestamps to distinguish added input and output delay. Do not assign a hardware loopback residual to a particular direction without an independent reference.
3. Inspect the private aggregate's actual callback timestamps, stream latencies and alignment. Derive the reporting model from the full path, including hidden-bridge timing and drift correction; a transport-margin sum alone is insufficient.
4. Implement separate Core Audio input/output latency publication and property-change notifications. Validate across rate/buffer changes and route changes, including channel-specific hardware latency limitations. Keep physical-interface calibration explicit and separate from software delay.
5. Repeat physical and recording-alignment checks against published properties. Correct reporting is not finished until readback and measured timing agree within a stated measurement uncertainty. Stability optimization follows this milestone.

Historical optimization stages below are retained as later work, not prerequisites for this reporting task. Preserve normal routing correctness while investigating. No background monitoring is scheduled.

## Read first

1. This plan.
2. [Baseline review and observations](LATENCY-REVIEW-2026-10-23.md).
3. [Run record template](../LATENCY-RUN-TEMPLATE.md).
4. `Sources/Core.hpp`, `Driver.cpp`, `Bridge.mm`, `RuntimePolicy.hpp`, `Preset.swift`, `App.swift`, and `RuntimeConnection.swift`.
5. `Tests/CoreTests.cpp`, `RouteTests.mm`, `RateTests.cpp`, `RuntimeIntegration.py`, and the chronological `VERIFICATION.md`.

The baseline is a dated observation, not a guarantee of current settings. Re-read the session and runtime status before any future experiment. The old README/verification entries describe earlier implementations; do not follow their manual start/stop or ad hoc signing instructions.

## Known working product behavior to retain

- A background service runs routing; the app is a control panel. Closing it must not stop audio.
- One source can feed multiple destinations; no summing and no automatic input/output loopback.
- Channel counts are independent. Hidden/dormant routes persist but carry no audio.
- Routes and device metadata use persistent UIDs, never saved transient AudioObjectIDs.
- Missing selected interfaces retain channels/labels in grey. Existing routes can be removed, not added. Reconnection is automatic.
- Sync Source drives sample-rate selection; per-device locks decide which other devices may be written, including on DAW requests. An unlocked device is never forced. A mismatched group remains muted.
- Failed synchronization: first attempt plus three immediate retries, then five seconds between attempts. Preserve notification deduplication and recovery notifications.
- Active named preset, unsaved session, labels, channel display order and routing persist. Asterisk compares user configuration against explicit save. Display reordering must not restart audio.
- Maintain the certificate identity shared by app and embedded service. Do not reset TCC or fall back to ad hoc signing.

## Historical baseline and unknowns (before 0.1.1)

Normal studio topology: UFX III via USB3, M-1610 Pro via MADI to UFX, ZED-R16 via FireWire/Thunderbolt; user reports ADAT synchronization with UFX as source. Verify actual external sync lock and firmware/driver versions at measurement time.

At review: 96 kHz, engine setting/reported I/O 32 frames, manual margin 64 frames each direction. Margin contributes 0.667 ms each way, 1.333 ms round trip. This is calculated, not measured total latency. Ring capacity 16384 frames is storage, not a corresponding fixed delay.

A separate Core Audio probe reported visible buffers of 512 frames, while the service reported engine I/O 32. Resolve which stream/callback each value describes before interpreting latency. Public queries cannot inspect another process's private aggregate. Do not substitute a previously observed Ableton buffer for its current setting.

Driver `spst` gave capture/playback missing-frame counts 0 / 13053952. They are cumulative read misses, not established audible-dropout counts. Reader multiplicity, idle clients, startup, resets and disabled transport complicate interpretation. `badBuffers` only validates callback data/layout; zero does not prove glitch-free audio.

No physical RTL, latency distribution, recording alignment or long-duration dropout rate has been measured. Current rate propagation, reconnect and UI checks do not establish these properties. Behind the virtual endpoint, bridge drift compensation may alter samples; bit transparency has not been established.

## Stage 0 — Freeze a reproducible baseline

- Preserve exact source, built app and installed driver separately. Record SHA-256 hashes, bundle versions and designated requirements. A newly built Dist driver may differ from the installed one.
- Back up `~/Library/Application Support/StudioPatch/last-session.json` and `presets.json` together, retaining active preset ID and unsaved changes. Save service plist and its executable path. Do not export private keys.
- Record macOS/hardware, connected devices/UIDs, driver versions, external clock lock, rate, client/engine buffers, channel counts, enabled routes, drift settings, TotalMix and ZED return routing.
- Capture runtime status, driver statistics and read-only properties. Timestamp every result and mark unavailable values explicitly.

Deliverable: a complete baseline run record. Stop if device identity, format, clock lock or actual buffer behavior is uncertain.

## Stage 1 — Trustworthy telemetry (first implementation task)

Instrument the existing signal path without changing buffer/margin policy.

- Distinguish no active writer, startup priming, intentional mute/reconfiguration, steady-state missing data, overwritten data and reader races. A valid block of zero samples is audio, not a missing producer.
- Separate capture and playback; record producer/consumer activity, last published frame and read range, callback size, requested versus actual engine buffer, rate, and reset/session generation.
- Collect callback duration, interval/deadline misses and timestamp headroom. Define headroom relative to the exact requested read interval, not just a global write position. Multiple readers require reader-aware interpretation.
- Keep telemetry bounded: no allocation, formatting, filesystem I/O, blocking locks or logging in audio callbacks. Use checked lock-free counters/bounded histograms and export from the control thread. Measure instrumentation overhead against the uninstrumented baseline.
- Driver statistics are optional reads. A failed diagnostic query must never block inventory updates, mute otherwise valid audio or restart the engine.
- Capture distributions and interval deltas, not just lifetime totals. Do not label unknown availability as zero errors. Preserve raw counters for diagnosis.
- Show concise diagnostic status in Advanced; detailed exports belong in a diagnostic report. Do not imply measurement of total latency until a loopback run exists.

Tests: idle reader, producer start/stop, zero audio, deterministic late writer, overwritten slot, wrap-around, concurrent readers, rate/session reset, muted transition and unavailable statistics. Verify exact expected classification and no stale samples after reconfiguration.

Exit: injected loss is detected; normal idle/startup is not called a steady-state dropout; instrumentation does not measurably worsen the baseline beyond measured run-to-run variation.

## Stage 2 — Physical baseline measurement

Select and document a spare line output and matching input with the user. UFX software playback mapping depends on TotalMix; ZED depends on its return controls. Exclude speakers/headphones from the test path and avoid feedback. Do not infer physical sockets from virtual channel numbers.

Use a calibrated pulse/sequence or correlation method at modest level. Record the generated reference, captured waveform, analysis method, sampling rate and raw sample offsets. Account for intentional DAW recording compensation: measure raw transport RTL separately from the compensated clip's alignment. Do not read clip placement alone as physical latency.

Compare with the SAME physical UFX path and client workload:

A. Direct UFX input/output.
B. StudioPatch with UFX only.
C. StudioPatch with UFX + ZED selected, same UFX loopback.
D. ZED loopback separately if needed; do not compare different converters as pure StudioPatch overhead.

For each configuration: initial five-second settling window (record separately), at least 100 pulses over at least 60 seconds, three repeated runs, then 30-minute loaded test. For a candidate release: an additional eight-hour representative soak. These durations are proposed test gates, not already completed work.

Report median/p95/p99/max RTL in samples and ms, variation, malformed/missing samples, telemetry deltas, CPU/callback cost and compensated recording offset. Sample count limits the strength of percentile estimates. Added latency = StudioPatch RTL minus matching direct baseline. A mixed-device route may have a different physical latency from another route.

## Stage 3 — Optimize measured CPU costs

Candidates: sequentially consistent atomic operations per sample in `Core.hpp`; route-by-route strided copying and clearing all aggregate outputs in `Bridge.mm`. Benchmark representative small, wide and fan-out configurations before choosing changes.

Do not replace atomic payloads with racy float arrays. Any memory-order relaxation/block publication must have a documented concurrency protocol supporting overwrite/wrap-around and multiple readers. Never skip clearing an output unless stale-audio prevention is proven. Keep the old implementation selectable in experimental builds for A/B comparison.

Exit: equivalent sample results, stress/race tests passing, callback-cost improvement outside baseline noise, and no worsening in physical loopback/stability. Lower CPU alone is not lower configured latency.

## Stage 4 — Hardware-referenced timing and latency reporting

Investigate using the selected hardware clock's sample/host timestamp relation for the virtual timeline. Present code anchors virtual timing to mach_absolute_time and drift-compensates the private bridge. Do not disable this correction without providing a coherent replacement.

Design before coding: clock ownership, cross-process publication, timestamp uncertainty, monotonicity/seed changes, rate switches, missing source, reconnect, sleep/wake, mixed client buffers and multiple simultaneous clients. Preserve mute-on-invalid-clock behavior.

Audit input and output latency reports end to end, including private aggregate and physical streams. Document how a single endpoint reports routes with differing hardware delays; do not assume one global number fits every channel. Correct metadata improves DAW alignment but does not remove physical delay.

Exit: coherent clocks and timestamp regression tests, drift/soak tests, correct alignment on measured paths, and fault recovery without stale output. This is a higher-risk experiment, not a prerequisite for making Stage 1 useful.

## Stage 5 — Reduce margins only with evidence

Current guard requires at least two actual engine I/O buffers. Automatic policy is four configured buffers per direction; manual 32/64 is already at the current guard. A change to 32/32 at 96 kHz would save only 0.667 ms of configured round-trip margin and requires a redesigned/validated safety rule.

Test a fixed candidate margin per configuration first. Do not silently adapt latency during recording: changing delay can skip/repeat samples and invalidate DAW compensation. Any future adaptive policy needs explicit transition semantics, reporting and recovery limits.

Exit: measurable improvement beyond baseline variation, all correctness gates passing, zero unexplained steady-state loss in the defined tests, and no new recovery regression. Retain conservative defaults unless the evidence supports promotion. Do not promise OMNIBUS parity without a comparable measurement setup and versioned results.

## Test matrix and acceptance decision

- Rates: 48 and 96 kHz initially; other supported rates later.
- Engine I/O: 32, 64, 128, 256; client: 64, 128, 256, 512 where supported. Cover both matching and mismatched sizes, not merely equal-size pairs.
- Channel layouts: small current session, typical studio routes, and widest supported real configuration at that rate. Include fan-out and silent/unmapped outputs.
- Direction: capture only, playback only, duplex, clients stopped/started and multiple clients.
- Load: idle, representative Ableton session, CPU/UI pressure; use identical workload for A/B.
- Transitions: device unplug/replug, clock mismatch, failed rate change/recovery, 48↔96, channel-count change, route change, app close/reopen, service restart, sleep/wake.

Do not require uninterrupted audio during intentional reconfiguration where the current contract allows muting. Do require bounded recovery and no stale/unintended output. Record observed recovery time rather than inventing a guaranteed deadline for third-party drivers.

Begin with a representative subset; expand only promising candidates. Decide numeric alignment/jitter thresholds before comparing final results, using baseline noise and the intended recording workflow. No numeric target is yet approved. Until then, results are exploratory, not proof of release readiness.

## Build, probe and artifact workflow

From the repository root:

```sh
export STUDIOPATCH_BUILD_DIR="$PWD/work/build"
/bin/bash Scripts/build.sh
/bin/bash Scripts/test-runtime.sh
clang++ -std=c++17 Tools/latency-probe.cpp -framework CoreAudio -framework CoreFoundation -o work/latency-probe
work/latency-probe
```

The build runs six CTest suites and signs bundles; it does not install them. Xcode macro compilation, Keychain signing and real Core Audio enumeration may require execution outside Codex's sandbox. An empty sandbox enumeration or zero visible signing identities is not evidence that the user's devices/certificates are missing.

The probe reads public device/stream latency, safety offset, visible buffer size and driver configuration/statistics. It does not start streams, play signals, measure RTL, or inspect another process's private aggregate. Its source is retained in `Tools/latency-probe.cpp`. Store raw output with run records.

Use `Scripts/install-driver.sh --replace` only for a deliberate driver experiment, after preserving a baseline and planning the audio interruption. Read the script first. Do not install a rebuilt driver merely to test UI/telemetry in the panel. A driver update may require a computer restart. Do not restart coreaudiod casually.

## Rollback

1. Stop the experiment and preserve logs/captures. Return client monitoring to a known safe state.
2. Restore the previous app/service bundle and service executable path, using the same signing identity. Coordinate service restart because it interrupts audio.
3. If the installed HAL driver changed, restore the verified previous driver through the reviewed installer workflow and restart macOS as required. Do not assume Dist is the installed version.
4. Restore paired session/preset backups only if the experiment changed them; preserve subsequent user edits separately rather than overwriting them silently.
5. Recheck device UIDs, physical clock lock, sample rate, buffers, routes and normal recovery. Record rollback outcome.

## Historical optimization resume checklist (reporting now implemented)

- [ ] Confirm the user's current setup and active preset; preserve unsaved edits.
- [ ] Snapshot baseline source/binaries/session and identify installed driver version.
- [ ] Implement Stage 1 metrics and classification tests, without lowering margins.
- [ ] Agree on physical loopback ports and measurement method.
- [ ] Complete Stage 2 baseline and choose quantified acceptance thresholds.
- [ ] Implement one candidate at a time; retain A/B and rollback evidence.

Open decisions: exact test ports/cabling, measurement client/tool, desired practical latency target, allowable recording-offset/jitter thresholds, acceptable maintenance interruptions and whether OMNIBUS will be available for a controlled comparison.
