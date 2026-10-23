# Latency reporting implementation and verification — 2026-10-23

This is the historical 0.1.1 reporting record. The later 0.2 direct transport and current measurements are in [LATENCY-DIRECT-2026-10-23.md](LATENCY-DIRECT-2026-10-23.md).

## Reporting contract

The user clarified that the visible device must report **selected Sync Source latency + StudioPatch's own latency**, separately for input and output. UFX III is currently that reference, including with ZED also selected. Latency differences of other interfaces do not change the reference. An independently measured error in the interface's report stays separate from StudioPatch's contribution. Correct reporting precedes stability optimization.

## Setup and evidence

The user connected UFX III analog output 3 to analog input 3 with TRS and confirmed TotalMix Software Playback 3 routing, no feedback, and isolation from speakers/headphones. Existing virtual channel 3 maps to UFX analog 3 in both directions. Both UFX and ZED remain selected. No session/preset routing was edited.

At 96 kHz, read-only HAL queries returned:

| Device | Input device / stream / safety (frames) | Output device / stream / safety (frames) |
|---|---|---|
| UFX III | 24 / 0 / 48 | 28 / 0 / 48 |
| StudioPatch | 0 / 64 / 0 | 0 / 0 / 0 |
| ZED | 59 / 0 / 288 | 59 / 0 / 128 |

The measurement client's device buffer was 512 frames. The service's private aggregate actually ran 32-frame callbacks; these are different client contexts, not contradictory observations.

`Tools/latency-capture.cpp` records one input channel and emits a low-level deterministic reference on one chosen output, with optional simultaneous input observation on another device. Samples and block host/sample timestamps are preallocated and saved after I/O stops. Tests used peak amplitude no greater than 0.008 (-41.9 dBFS) and six-second captures. The final reference is filtered with an eight-sample moving average; the actual emitted reference is saved, so that filter is not counted as path delay.

`Tools/analyze-latency.py` correlates five 4096-sample windows and converts matched positions with the actual callback host timestamps. These results are **timestamp-referenced path delay**, not an application's full software-monitoring round-trip delay. Buffer/safety scheduling is already represented in those timestamps and must not be added twice. Raw captures and JSON analyses are in ignored local `work/latency/`.

## Initial observations before the reporting fix

- `direct-01`: unfiltered reference had correlation around 0.65–0.68; rejected by the 0.8 quality threshold. Do not use its apparent peak as the final hardware measurement.
- `direct-02`: filtered reference, direct UFX output/input, approximately **57 frames**, correlations 0.953–0.961. Reported hardware sum is 52 frames, giving an approximately **5-frame residual**. The user independently reports a similar prior result from RTL Utility. This does not determine which direction owns the residual; converter filtering and integer-sample correlation limit precision.
- `patch-01` and `patch-02`: same cable via StudioPatch, approximately **1329 frames** in all five windows of each run, correlations 0.953–0.961. Relative to the direct reference, approximately **1272 frames** of added timestamp-referenced delay in this setup. Do not generalize this constant to other rates, buffers or service sessions.
- Concurrent direct UFX input observation reveals that the apparent allocation between input and output changes across service restart, while the summed loopback stays near 1329. It is therefore **not valid to hardcode the directional split from one run**, assume symmetry, or claim that transport margin alone describes the path.

After the diagnostic service build/restart, the actual aggregate reported:

```json
{"callbackFrames":32,"actualBufferNow":32,"ioTimestampGap":546,
 "input":{"latency":24,"safety":323,"streams":[{"start":1,"latency":0},{"start":95,"latency":0},{"start":113,"latency":64}]},
 "output":{"latency":28,"safety":159,"streams":[{"start":1,"latency":0},{"start":95,"latency":0},{"start":113,"latency":0}]}}
```

The callback's output-minus-input timestamp difference is 546 frames = 2 × 32 + 323 + 159. This is direct evidence of additional timing in the routing path. It is not yet a complete formula for visible input/output latency: hidden-bridge alignment and clock mapping still need to be accounted for. The original callback ignored these timestamps entirely.

## Initial diagnostic changes and validation

- Added the capture/analyzer tools and optional runtime diagnostics for actual callback frames, timestamp gap and aggregate properties. Diagnostic property failures are isolated from routing; a missing reading is explicitly unavailable.
- Six existing CTest suites passed. Separate runtime integration suite passed. A synthetic 57-frame delay verified correlation/index/host-time arithmetic.
- The signed app/service was built and the service restarted to expose diagnostics. It returned to active 32-frame routing with zero reported buffer-layout errors. No new HAL driver was installed and no driver latency reporting fix has been applied yet.
- Previous app, installed driver, paired session/preset files and launch-agent plist are preserved under `work/latency/baseline/`. Captures are exploratory, not release acceptance evidence.

## Installed implementation: 0.1.1

The reporting fix is built, signed, installed and loaded. The previous HAL driver is preserved at `/Library/Audio/StudioPatch Backups/previous.i4ydDd/StudioPatch.driver`; the initial app/service and paired settings backup remain in `work/latency/baseline/`.

Two complementary floating-point time ramps travel in the final two channels of each **hidden** bridge stream. These internal channels are excluded from the user-facing channel counts, audio timeline payload and physical routing. They identify the source timestamp of the actual samples even after aggregate alignment/drift conversion. Invalid silence and wrap neighbourhoods are rejected. No HAL queries, memory allocation or property notifications occur in the audio callback.

For capture, the service marks the aggregate input host timestamp; the driver compares its received time plus ring delay with that reference. For playback, the driver marks the original visible output frame; the service compares it with the aggregate output host timestamp. Both use the driver's shared host-time anchor. This measures each direction independently without requiring a physical cable or audible test signal in normal operation.

The service adds the selected Sync Source's device latency and largest stream latency for each direction (all UFX streams in these runs report zero). It publishes generation-bound, rounded integer frame totals through `splt`; the driver exposes these as input/output `kAudioDevicePropertyLatency` and sends corresponding property notifications. Visible stream latency and safety offset are zero. Internal bridge input stream latency still describes its own transport delay; it is not counted a second time in visible properties. A 100 ms control-thread timer follows slow clock alignment changes independently of the UI inventory timer. Values become available after timing-reference acquisition when routing starts.

The hardware residual is intentionally excluded: the requirement is Sync Source's reported latency + StudioPatch's own measured addition. Other routed interfaces can differ from that reference. The client's own buffer scheduling is not included in device/stream latency; clients/DAWs account for that separately.

## Physical verification of input AND output

`Tools/verify-latency-report.py` compares time-aligned, continuously sampled HAL reports against an independent simultaneous UFX input observation:

- Added capture delay = StudioPatch loopback timestamp delay minus simultaneous direct UFX input observation of the same samples.
- Added playback delay = direct UFX observation of StudioPatch playback minus independently measured direct UFX loopback delay.
- Expected reported input/output = the respective added delay + UFX's reported input/output hardware latency.

The direct UFX hardware loopback is used to cancel the complete physical path in the playback comparison; it is never divided into guessed one-way hardware delays. Reference windows correlate above 0.95. Each run checks five windows; this is reporting validation, not a stability soak.

| Configuration | Reported sum (frames) | Physical timestamp-referenced loopback | UFX residual | Largest direction error |
|---|---:|---:|---:|---:|
| 96 kHz, engine 32, margin 64, after service restart | 1324 | 1329 | 5 | 0.264 frames |
| 96 kHz, engine 64, margin 128 | 1580 | 1585 | 5 | 1.128 frames |
| 48 kHz, engine 32, margin 64 | 724 | 729 | 5 | 0.604 frames |
| Restored 96 kHz, engine 32, margin 64 | 1324 | 1329 | 5 | 0.544 frames |

Direction values vary with the actual clock alignment; they are not fixed halves of the sum. For example, the final readback was 693 input + 631 output, then the diagnostic snapshot was 694 + 630 as alignment evolved. This is why the runtime timing reference and change notifications are necessary. Largest observed error was approximately 1.13 frames across these 20 windows; integer rounding, measurement timestamps and finite update intervals limit precision. Exact zero-error or all-configuration accuracy is not claimed.

The direct hardware checks yielded 57 vs 52 reported frames at 96 kHz and 41 vs 36 at 48 kHz: the same 5-frame residual. No correction for that residual was introduced.

Raw `.f32` captures, timestamp/report CSVs, per-run verification JSON, installed hashes and the summary are under `work/latency/`; the summary is `reporting-verification-summary.json`. The verifier asserts valid correlations, direction errors below 1.5 frames, and reported-sum residual equal to the independent hardware residual. The 1.5-frame numerical check describes this test run's acceptance, not a guarantee across untested hardware.

## Validation and restored state

All six CTest suites passed, including new generation rejection, independent directional property reads, timing-ramp decoding and strided duplex transport checks. The separate runtime integration suite passed. The initial capture/analyzer was also checked with a synthetic known 57-frame delay.

The user's session is semantically identical to `reporting-session-original.json` after restoration: **96 kHz, engine 32, margin 64**, same selected devices, routes, labels and preset state. The service is active. The new driver is installed; no reboot is outstanding for this run (Core Audio was deliberately restarted and the loaded properties verified).

## Remaining scope

Long-duration stability and optimization remain deferred at the user's request. Individual DAW recording-compensation behavior, other interfaces as Sync Source, and other rates/buffers have not been physically verified. The implemented HAL reporting is verified for the configurations above; the approximately 5-frame UFX hardware residual remains separate.
