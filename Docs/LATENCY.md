# Latency

StudioPatch aims to add **at most about 1 ms of round-trip latency** compared with using the Sync Source interface directly, while reporting its latency correctly to the DAW and without losing audio. This page summarizes what has been measured and how to measure it yourself.

## How much latency StudioPatch adds

StudioPatch adds a fixed software margin in each direction:

```text
margin per direction = max(ceil(sampleRate / 3000), engine I/O buffer) frames
```

With the default engine I/O buffer of 32 samples:

| Sample rate | Margin in / out | Added round trip |
|---|---:|---:|
| 96 kHz | 32 / 32 frames | 64 frames = **0.667 ms** |
| 48 kHz | 32 / 32 frames | 64 frames = **1.333 ms** |

A larger engine I/O buffer increases both margins (64 samples → 64 + 64 frames). This is the buffer StudioPatch uses towards the hardware, set under **Advanced** in the panel. Your DAW's buffer is separate and adds the same latency with or without StudioPatch.

The 48 kHz result misses the 1 ms target on purpose. A 16-frame output margin measured 1.0 ms but produced short bursts of corrupted playback under heavy CPU load, so the margin is never smaller than one engine buffer. A lower-latency mode would need its own qualification.

## Measured results

Measured with a physical cable from analog output 3 to analog input 3 on an RME UFX III (Sync Source), with an Allen & Heath ZED-R16 also selected as a clock-locked secondary interface. Engine I/O buffer 32, measurement client buffer 256.

| Sample rate | Direct UFX III round trip | Through StudioPatch | Added |
|---|---:|---:|---:|
| 96 kHz | 665 frames / 6.927 ms | 729 frames / 7.594 ms | 64 frames / 0.667 ms |
| 48 kHz | 601 frames / 12.521 ms | 665 frames / 13.854 ms | 64 frames / 1.333 ms |

Other observations:

- At 96 kHz the added latency was the same 64 frames with client buffers of 64 and 512.
- Reported input and output latency matched independent measurements within about 1.4 samples in each direction. The UFX III has a hardware residual of about five frames between its own report and the measured loopback; StudioPatch does not hide or redistribute it.
- Waveform comparisons over 15–120 second runs, including runs with heavy synthetic CPU load, routing changes during playback and extra clients starting and stopping, found no missing or corrupted audio with the current margins.
- 449,280 consecutive samples from a ZED-R16 input were bit-identical through StudioPatch.

These are short, controlled tests on one setup. They are not a long-duration soak test, and they do not cover other interfaces, other sample rates or every buffer size. See [STATUS.md](STATUS.md) for the full list of what is and is not verified.

## What StudioPatch reports to the DAW

For each direction, the StudioPatch device reports:

```text
latency = Sync Source device latency + largest Sync Source stream latency + StudioPatch margin
```

Safety offsets equal the Sync Source's. The DAW adds its own buffer on top, as with any interface.

Reporting always refers to the **Sync Source**. A route from a secondary interface can have a different real latency; the panel's **Advanced** section shows each secondary interface's calculated difference. These are estimates from reported values, not measurements of the analog path.

Expected DAW figures at 256 samples, with a five-sample error compensation for the UFX III: about **7.59 ms** overall at 96 kHz and **13.85 ms** at 48 kHz.

## Measuring latency

The `Tools/` directory contains the tools used for the measurements above. All of them run as your normal user and never install anything or restart services.

> **Safety.** The capture tool plays a low-level noise signal (peak about −42 dBFS) on the output channel you choose. Use an isolated loopback cable, make sure that output does not reach speakers or headphones, and check that your interface's mixer does not create feedback.

1. **Find device UIDs.** `Dist/patch-inspect` prints all devices and channels as JSON. The StudioPatch device's UID is `se.studiopatch.device.v1`.

2. **Capture.** `latency-capture` is built by `Scripts/build.sh` into your build directory. Run it through the bounded runner, which limits duration, stops the capture if Core Audio uses more than 80% of a CPU core for ten seconds, and records the service status during the run:

   ```sh
   python3 Tools/run-hardware-capture.py --capture build/latency-capture \
     --uid <device-uid> --input 3 --output 3 \
     --seconds 30 --buffer 256 --prefix work/capture-001
   ```

   Run it once against the interface directly and once against the StudioPatch device, using the same physical channels and buffer.

3. **Analyze.** Find the round trip and check signal integrity:

   ```sh
   python3 Tools/analyze-latency.py work/capture-001-output work/capture-001-input > work/capture-001-analysis.json
   ```

   `duplex_round_trip_frames` is the round trip as an application sees it, including its own buffer scheduling. The `measurements` field contains timestamp-referenced path delays, which exclude that scheduling. Do not mix the two.

4. **Compare runs** (optional). `Tools/compare-captures.py REFERENCE_PREFIX CAPTURE_PREFIX` compares the received waveform of two analyzed captures window by window, which detects short dropouts that correlation over long windows can miss.

5. **Verify the reported latency** (optional). Capture through StudioPatch with the Sync Source's direct input as a simultaneous observer, then run `Tools/verify-latency-report.py`. See the usage notes at the top of that script.

`Tools/latency-probe.cpp` is a read-only probe of the latency, safety offset and buffer properties of all devices:

```sh
clang++ -std=c++17 Tools/latency-probe.cpp -framework CoreAudio -framework CoreFoundation -o build/latency-probe
build/latency-probe
```

Use [LATENCY-RUN-TEMPLATE.md](LATENCY-RUN-TEMPLATE.md) to record runs. Put raw captures in `work/`, which Git ignores.

### Measurement-only switches

These environment variables exist for controlled experiments. Do not leave them set in the installed service.

| Variable | Used by | Effect |
|---|---|---|
| `STUDIOPATCH_TEST_BUFFER` | `latency-capture` | Sets the capture client's buffer size. |
| `STUDIOPATCH_TEST_SECONDS`, `STUDIOPATCH_TEST_STREAM`, `STUDIOPATCH_TEST_LOAD` | `latency-capture` | Capture length, streaming to disk for long runs, synthetic CPU load (0–0.95). |
| `STUDIOPATCH_TIMING` | Service | Enables timing telemetry in the runtime status. |
| `STUDIOPATCH_TEST_OUTPUT_PADDING` | Service | Overrides the output margin. For A/B tests only; small values are known to corrupt audio under load. |

## History

The path to the current design, including the earlier hidden-bridge architecture (which added about 12 ms) and rejected lower-latency candidates, is documented in [history/](history/README.md).
