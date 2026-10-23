# Direct transport: implementation and physical verification

Date: 2026-10-23. Candidate version: 0.2.0. This supersedes the 0.1.1 hidden-bridge architecture. The user requires at most approximately 1 ms added round trip over the selected Sync Source, accurate input/output reports, and no significant stability regression. Short hardware tests are not a full release qualification.

## Architecture and reporting

The visible AudioServerPlugIn and background service share tagged atomic sample storage through an authenticated launchd broker. The broker accepts the Apple Core Audio host and the certificate-signed StudioPatch service. All XPC setup is on control threads, with a three-second response timeout; the audio callbacks only access mapped data. Capture and playback are independent. Missing/overwritten samples are zero, and a stale hardware clock mutes the transport. Each service start receives fresh storage and a generation, so an old sample counter cannot revive stale samples.

Sync Source's physical callback publishes its sample/host clock. Native Float32 samples on that path are copied without DSP or resampling. Other externally synchronized interfaces use separate callbacks. Independently clocked secondary interfaces use Apple's drift compensation in private aggregates; only their own routes pass through those aggregates. The old hidden bridge is not part of the live transport. User-created aggregates are not modified.

Capture margin is `max(ceil(rate/3000), actual Sync Source engine buffer)` frames; output margin is `ceil(rate/3000)` frames. A full hardware block on capture prevents callback-phase-dependent missing samples. At engine buffer 32, this is input/output 32/32 at 96 kHz and 32/16 at 48 kHz. Larger engine buffers can exceed the target. Old `delayFrames` and automatic-margin preset fields remain readable but do not control the direct transport.

For each direction, `kAudioDevicePropertyLatency` is the Sync Source device latency + largest stream latency + that direction's StudioPatch margin. Stream latency is zero on the visible endpoint. Safety offsets equal Sync Source's safety offsets and remain separate from device latency and the DAW's buffer. Timing changes go through `RequestDeviceConfigurationChange`, as required by Apple's installed `AudioServerPlugIn.h`; startup waits for HAL to confirm safety offsets. Property-change notification alone did not update Core Audio scheduling and was rejected during testing.

Reporting is intentionally referenced to Sync Source. Other interfaces can have different real path delays. The roughly five-frame UFX hardware residual is preserved separately, not arbitrarily assigned to input or output.

## Physical measurement method

UFX III output 3 is cabled to input 3, with the user's confirmed TotalMix routing, no feedback and speaker isolation. Virtual channel 3 maps to these channels. UFX and ZED remain selected. Signal peak is at most 0.008 (about -42 dBFS), filtered deterministic noise; only output 3 receives it.

`Tools/latency-capture.cpp` records actual samples and input/output timestamps. `STUDIOPATCH_TEST_BUFFER=256` explicitly sets the measurement client's buffer; the service's hardware callback buffer is independently 32. `STUDIOPATCH_TEST_SECONDS=30` extends a capture. The tool leaves the measurement process's requested buffer in place until process exit and does not edit default audio devices or routing.

`Tools/analyze-latency.py` checks timestamp/sample continuity, correlates five windows distributed across the signal, and checks every 1024-sample window of its central span. For same-callback duplex captures, matched input minus output array index gives software-monitoring RTL, including the client's scheduling gap. Host-time-referenced delay excludes that scheduling gap. These two quantities must not be confused.

`Tools/verify-latency-report.py` uses simultaneous direct UFX input observation to separate StudioPatch's two software delays. This does not claim to split the converter hardware residual. Host timestamp/correlation uncertainty is around one to two samples. Raw data and JSON analyses are retained in ignored `work/direct-path/`.

## Results at 256-frame client buffer and 32-frame engine buffer

| Rate | Direct UFX duplex RTL | StudioPatch duplex RTL | Extra | HAL device latency in / out | Safety in / out |
|---|---:|---:|---:|---:|---:|
| 96 kHz | 665 frames / 6.927 ms | 729 frames / 7.594 ms | 64 frames / 0.667 ms | 56 / 60 frames | 48 / 48 |
| 48 kHz | 601 frames / 12.521 ms | 649 frames / 13.521 ms | 48 frames / 1.000 ms | 49 / 35 frames | 24 / 24 |

The 96 kHz timestamp-referenced loopback is 121 frames vs 57 direct; at 48 kHz it is 89 vs 41. The report sums (116 and 84) are five frames below the measured loopback, exactly matching direct hardware's residual. With Ableton's existing five-sample error compensation, expected overall values are approximately 7.59 ms at 96 kHz and 13.52 ms at 48 kHz, both at 256 samples. These are expectations from HAL/cable verification, not a new screenshot of Ableton.

At 96 kHz expected DAW input/output displays are approximately 3.75/3.79 ms. At 48 kHz they are approximately 6.85/6.56 ms. Do not hide excess latency by changing these reports.

The existing user aggregate had both UFX and ZED selected when measured: 1,051 frames / 10.948 ms at 96 kHz / 256, with safety offsets 323/159. Its timestamp-referenced physical path was still 57 frames. This does not contradict the user's single-UFX aggregate screenshot: an aggregate containing only UFX can expose the same timing as UFX directly. The former all-device hidden bridge combined additional scheduling with virtual-to-physical handoff.

## Rejected intermediate results

- First direct candidate published safety-offset notifications without a device configuration change. HAL retained zero offsets; capture had regular 36-frame gaps every 256 frames. Its apparently low RTL was invalid.
- After safety-offset configuration, one full silent block was traced to treating slightly future predicted HAL clock timestamps as stale. Fresh predictions are now accepted within the bounded age check. A following 30-second 96 kHz run had no missing blocks.
- Symmetric 16/16 padding at 48 kHz produced short periodic gaps. It was rejected. The final 32/16 split measured 1 ms extra and had no detected missing blocks over 30 seconds.

## Validation and limits

Seven CTest suites pass, including cross-process sample visibility, independent capture/playback, fan-out, overwritten-frame silence, clock freshness, secondary clock translation and malformed-buffer muting. The service integration suite passes format changes, retry/recovery, routing edits, missing hardware and reconnect scenarios with simulated hardware.

Live 96→48→96 kHz transitions recovered automatically. Thirty-second physical runs at 48 and 96 kHz showed constant sample-index delays and no multi-sample zero runs or low-correlation windows; isolated zero-valued ADC samples also occur in the direct reference. Enabling Apple drift correction on ZED left the UFX path at 729 frames with intact audio. ZED's analog path was not independently cabled or measured.

Additional measured checks on the installed candidate:

- **CPU load:** four bounded CPU workers during separate 30-second direct and StudioPatch captures at 96 kHz / 256. RTL remained 665/729 frames. Each capture had 2,493 integrity windows, minimum correlations 0.932285/0.932300, zero low-correlation windows, and longest zero runs of one sample. No missing audio block was detected.
- **Service restart:** runtime returned to active after approximately 1.47 seconds; a subsequent physical capture passed. Intentional restarts mute audio during recovery.
- **64-frame client buffer, 96 kHz:** direct 281 vs StudioPatch 345 frames; 64 added, intact signal.
- **512-frame client buffer, 96 kHz:** direct 1,177 vs StudioPatch 1,241 frames; 64 added, intact signal.
- **Final 48 kHz / 256 capture:** 30 seconds, 649 frames, 1,246 integrity windows, minimum correlation 0.949057, longest zero run one sample. The largest directional reporting discrepancy across the five observation windows was 1.332 samples.
- **Secondary drift enabled, 96 kHz / 256:** 729 frames, no missing blocks, largest directional discrepancy 0.380 samples. This verifies the UFX route while the secondary correction is running, not the secondary converter's latency.
- **After restart, 96 kHz / 64:** largest directional discrepancy 0.720 samples.
- **ZED passive input:** simultaneous direct ZED input 1 and StudioPatch virtual input 11, no emitted test signal. All 449,280 compared samples were bit-identical after a constant index translation. This verifies the existing clock-locked secondary capture route independently of UFX loopback; ZED output remains covered by routing tests rather than a physical cable measurement.

The service's raw shared-memory miss counters include startup and periods without a virtual playback client; they are not dropout counts. The independent waveform checks above are the evidence for signal continuity. The old generic ring counters from `latency-probe` refer to the unused legacy bridge and should not be interpreted as direct-transport telemetry.

The app, driver and broker signatures were verified. Installed driver SHA-1 is `e7304aa0f7b55e14230cc5c84151757c8bf90471`, identical to Dist. The final service is active at 96 kHz, 32-frame engine I/O, UFX Sync Source, with UFX and ZED selected and drift correction off as originally configured. Input/output counts remain 46/40. Routing/labels and all session settings apart from the separately changed active preset ID match the pre-experiment snapshot; later preset-library changes were preserved rather than overwritten with the old backup.

 Full-duration DAW load, all supported rates/interfaces, physical hot-unplug, sleep/wake, and long soak tests remain unqualified. Do not extrapolate the 1 ms result to every engine-buffer choice or every interface's minimum callback size.

## Installation and recovery

Install the signed broker with `Scripts/install-transport.sh` before installing the matching driver. Its root-owned files are `/Library/PrivilegedHelperTools/se.studiopatch.transport/` and `/Library/LaunchDaemons/se.studiopatch.transport.plist`. The broker checks service signing requirements rather than granting arbitrary user processes audio-memory access. Driver installation checks that the matching broker is loaded. The app/service remain signed with the existing persistent identity.

Pre-experiment app/service, installed driver, session/presets and source diff are in `work/direct-path/baseline/`. The pre-direct 0.1.1 installed driver is also preserved at `/Library/Audio/StudioPatch Backups/previous.1rgk9q/StudioPatch.driver`. Restore the app/service and driver as a matching pair if reverting; do not overwrite later user presets with old backups. Installer backups named `previous.*` after that point contain intermediate direct builds, not necessarily the 0.1.1 reference.
