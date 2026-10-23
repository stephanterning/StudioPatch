# StudioPatch latency review — 2026-10-23

## Evidence

Configuration inspected: 96 kHz, engine I/O 32 frames, manual transport margin 64 frames per direction. No audio settings were changed during this review.

Driver.cpp reads each timeline at requested sample time minus config.delay. The configured margin therefore contributes 64/96000 = 0.667 ms per direction, or 1.333 ms round trip. This is not measured physical round-trip latency. The 16384-frame timeline capacity is not a 16384-frame audio delay.

Read-only Core Audio probe (../../Tools/latency-probe.cpp):

| Visible device | Buffer frames | Input device latency / safety offset | Output device latency / safety offset |
|---|---:|---:|---:|
| UFX III | 512 | 24 / 48 | 28 / 48 |
| ZED-R16 | 512 | 59 / 288 | 59 / 128 |
| StudioPatch | 512 | 0 / 0 | 0 / 0 |

All values above are frames. StudioPatch additionally reports 64 input stream latency frames and zero output stream latency. Private aggregate/bridge properties are not exposed to this standalone probe. The service reports its engine buffer as 32 frames. Do not infer that all callbacks use 512 frames, nor that Ableton's current buffer is 32, from these separate readings.

The public latency report does not propagate the physical path's full latency. Correcting reporting is needed for recording alignment; it does not itself reduce audible delay.

## Stability blind spot

Bridge.mm badBuffers counts invalid buffer layout/data conditions. It does not count timeline starvation. Core.hpp maintains capture/playback missingFrames, exposed by Driver.cpp through spst. The probe returned capture 0 / playback 13053952 cumulatively. This is not a count of proven audible dropouts: inactive clients, startup and intentional silence need classification, and counts may include repeated reads. Current '0 buffer errors' cannot establish dropout-free operation.

## Prioritized work

1. Instrument before reducing margins. Collect read misses per direction with active producer/consumer state, callback duration/deadline statistics and timestamp headroom. Keep recording allocation-free and lock-free in callbacks; aggregate off the audio thread. Capture actual engine and client buffer sizes separately. Report unavailable metrics as unavailable.
2. Establish physical loopback baselines on the same UFX input/output at identical sample rate, client buffer and DAW processing: direct UFX, StudioPatch UFX-only, then StudioPatch UFX+ZED. Repeat under CPU/UI load and over long sessions. Measure latency variation as well as median/max latency and recording offset. Do not route test tones without selecting safe output/input paths.
3. Benchmark callback cost. The timeline uses sequentially consistent atomic operations for every sample; routing clears all aggregate outputs and copies selected routes sample-by-sample. Optimize only proven hot paths. Do not replace atomics with unprotected float arrays or weaken memory ordering without a valid wrap-around/concurrent-reader protocol and race tests. Lower CPU cost provides headroom; it does not by itself remove configured delay.
4. Investigate hardware-referenced virtual timing. The private aggregate includes a drift-compensated virtual bridge; its timestamp clock is based on mach_absolute_time rather than UFX timestamps. A shared hardware-referenced timeline may reduce synchronization overhead, but this requires clock recovery, disconnect, rate-change and multiple-client tests. Do not simply disable bridge drift correction.
5. Only then compare smaller per-direction margins. Current code enforces at least two engine buffers; lowering 64 to 32 at 96 kHz would save at most 0.667 ms of configured round-trip margin but violates that existing guard. Treat it as an experimental architecture change, not a safe default toggle. Prefer a validated fixed margin per configuration before attempting adaptive latency, which can complicate DAW compensation and discontinuities.

Acceptance: no unexplained missing audio during steady-state loaded playback/recording; stable latency distribution; correct recording alignment; recovery across device changes; regression checks at multiple DAW and engine buffer sizes and rates. No finite test guarantees absolute stability, and no claim of matching OMNIBUS latency can be made without comparable measurements.

Implementation and resumption details: [Latency plan](LATENCY-PLAN.md).
