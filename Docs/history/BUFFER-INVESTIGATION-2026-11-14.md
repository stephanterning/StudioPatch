# Playback gaps with large engine buffers — 2026-11-14

The owner reported clicks in Ableton Live playback through StudioPatch to UFX III outputs 1/2, worse with a 1024-frame engine buffer than with 32 frames. Ableton's buffer was 512 frames at 96 kHz, with its CPU meter around 27%. The service from the November 12–13 two-block transport-margin fix was still running; its 1024-frame configuration reserved 2048 frames in each direction.

## Retained evidence

Comparable three-minute windows on November 14 (Europe/Stockholm):

| Window | Engine buffer | UFX missing channel-samples / incomplete blocks | ZED missing channel-samples / incomplete blocks |
|---|---:|---:|---:|
| 22:49–22:52 | 32 | 146,470 / 26 | 98,299 / 92 |
| 22:54–22:57 | 1024 | 425,711 / 78 | 270,304 / 73 |

Neither window added capture misses, physical input/output timeline gaps, malformed buffers, invalid timestamps, counter resets, realignments or routing updates. Incomplete-block counts depend on block size. The missing-sample counters include all configured output routes, even those carrying silence; they are not counts of audible clicks on outputs 1/2.

Many losses affect both interfaces together and normalize to approximately 384 missing frames per routed output (9,600 channel-samples across 25 UFX routes and 6,144 across 16 ZED routes). Logs alone do not distinguish late publication, skipped frames or overwritten storage. The 32-frame setting also had losses that evening, although an earlier 73-minute interval was clean.

Core Audio's overload records identify another active client on the same virtual device: Safari's `com.apple.WebKit.GPU` process, using 128-frame callbacks. Of 4,134 retained overload records between 22:52 and 23:00, 4,131 belong to that reporter. The records include client timeouts and safety violations. HAL's process inventory and LaunchServices identify the process as Safari Graphics and Media; Ableton is a separate 512-frame client. This is evidence for investigating their interaction, not proof that Safari alone causes StudioPatch's missing samples.

The owner then quit Safari while Ableton kept playing. HAL confirmed that Ableton was the sole remaining client of the virtual device. From 23:01:54 to 23:03:26, the same 1024-frame engine generation processed 8,625 callbacks per interface with zero new capture/playback misses, incomplete blocks, timeline changes, buffer errors or timestamp errors. The owner also reported that the audible clicks appeared to disappear. No service or driver was restarted. This isolates a reproducible multi-client interaction; closing another application is not an acceptable product fix. Concurrent use by multiple audio applications remains required.

Reconstructing Safari's client anchor host time from its logged cycle start and frame counter places 107 of 119 retained common-loss observations within 15 ms of a new Safari anchor. Median signed separation is +3.02 ms. The correlation is consistent with client resynchronization affecting the mixed output timeline, but does not distinguish missing HAL mix ranges from StudioPatch reading before publication.

Raw observations and read-only probe sources/results are preserved under `work/buffer-investigation-2026-11-14/` (ignored by Git). A read-only current-time probe could not obtain device clocks without starting its own I/O and was not used as clock evidence. Buffer properties queried by a separate process do not establish the running service's actual callback size.

## Independently reproduced clock defect

`HardwareTimeline::get` could return the previous 16,384-frame period under the same epoch when a refreshed clock slightly moved the estimated period boundary backwards. A regression fixture reproduces the failure with monotonically increasing host queries and hardware clock observations. The local correction retains an already-reported period until a later period or a new epoch arrives.

The fixture failed before the change and passes afterward. The driver builds, and the core, direct, transport-timing and bridge-fault suites pass. The change does not alter shared-memory layout. It requires an updated driver to take effect and has not been installed. The existing scheduling fixture bypassed `HardwareTimeline`, so it could not catch this defect. Its relationship to the reported clicks remains unproven.

## Driver copy cost

The shared transport stores each channel in a separate plane, but the driver's direct input/output loops traversed frames before channels. Changing those two loops to traverse channels before frames preserves the sample indices, atomic frame tags and missing-frame silence while avoiding repeated large-stride accesses.

An isolated optimized build benchmark calls the actual old and new `patch::Handler` implementations with 44 input and 36 output channels, 2,000 iterations per block size and no missing capture frames. Combined input-read plus output-write median / p99 costs were:

| Frames | Before, microseconds | After, microseconds |
|---|---:|---:|
| 512 | 524.7 / 655.0 | 44.7 / 97.1 |
| 1024 | 1043.0 / 1228.8 | 115.8 / 195.5 |

The existing core and exact transport-delivery tests pass. This establishes a substantial reduction in driver work while holding libASPL's I/O serialization lock. It is not yet a live verification of the multi-client symptom. This correction also requires installing the updated driver; it is not active in the running system.

## Approved diagnostic activation and bounded measurement

The owner approved two brief service interruptions. A service-only build was signed with the existing identity, checked against the installed broker requirement, and activated at 23:18:26 Stockholm with `STUDIOPATCH_TIMING` enabled for that process. The global launchd environment was immediately restored after startup confirmation. Driver and broker were not replaced or restarted. The previous app and settings are preserved in `build/multiclient-diagnostics/`.

The service-local observer reads the existing bounded driver publication log. It counts forward/backward steps between consecutive publication ranges and explicitly does not interpret those steps as missing coverage. Lost or incoherent records break the comparison baseline. Coherent, bounded event snapshots retain frame, host and tag details for failed playback reads. Retained logs and ZIP export preserve this timing-only evidence. No samples are recorded and no diagnostic changes routing or recovery behavior.

Safari's new Graphics and Media process started at 23:18:34. During 23:18:58–23:19:57, Ableton and Safari were both connected to the virtual device at 1024 engine frames. The observer consumed 45,000 publications with no lost/unavailable observations or forward/backward jumps. Capture and playback misses stayed unchanged; each interface processed 5,625 callbacks with zero new buffer, timestamp or physical timeline errors. The only last-failure metadata described startup, before the measured interval. No ongoing fault was reproduced.

At 23:20:40, the second approved service restart disabled extra timing while both clients remained active. A further 40-second observation processed 3,750 callbacks per interface with zero new capture/playback misses or physical callback errors. That restart produced service ID `A7DD5D82-3402-4963-ADE1-2ED077CAC8A4` and generation `7286294626724`, with timing disabled. Driver, broker, session, presets and source-label SHA-256 hashes matched their pre-activation values. Evidence includes `multiclient-live-summary.json`, `multiclient-live-analysis.json`, `after-diagnostic-restart-summary.json`, and `build/multiclient-diagnostics/timing-disabled.json`.

The separately signed driver artifact in `build/multiclient-driver/StudioPatch.driver` contains the clock and copy-order corrections. Its binary SHA-256 is `505b98aded25a0fbb775dc8f63fcf99968a1913c7b1c43df81273cef01a4aa6d`. It remains uninstalled; the clean measurement used the original driver.

## Active-client reconfiguration probe

An isolated probe using the real Endpoint and two simulated active clients confirms that an unchanged-format session replacement recreates stream IDs, resets safety offsets to zero, and exposes a ready mapping before its hardware clock is available. Clients can observe a fallback clock followed by a second seed change when the physical clock arrives. Buffer-only engine changes currently use this full replacement path.

The probe does not reproduce persistent client timeouts. Avoiding that transition is not a one-line change: an in-place buffer update must explicitly handle decreasing transport padding and preserve timestamp semantics. Evidence is in `work/reconfiguration-audit-20261114/`.

## Approved buffer cycle with both clients active

The owner separately approved 1024 → 32 → 1024 while Safari and Ableton remained open. The changes were made through the native StudioPatch panel, preserving its exclusive ownership of the saved session file. HAL process inventories before and after identify the same active Ableton and Safari audio processes.

| Setting | Measured interval (Stockholm) | Callbacks UFX / ZED | New capture/playback misses |
|---|---|---:|---:|
| 32 | 23:34:39–23:35:09 | 89,996 / 89,995 | 0 / 0 |
| 1024 | 23:35:49–23:36:48 | 5,531 / 5,531 | 0 / 0 |

Neither steady interval added incomplete playback blocks, physical timeline changes, malformed buffers or invalid timestamps. Each generation's first retained observation included one partial UFX block (6,700 missing channel-samples at 32; 30,075 at 1024), with no further increase. Core Audio log errors were confined to the two configuration-transition bursts, ending at 23:34:34.712 and 23:35:33.775 respectively. No overloads were logged during either steady interval. Publication timing was disabled for this cycle, so it provides no publication-sequence evidence.

The final engine generation is `7307718364022`, running at 1024 frames in the same service process. The saved session matches the pre-test JSON exactly. Evidence is in `buffer-cycle-32-summary.json`, `buffer-cycle-1024-summary.json`, `buffer-cycle-restored.json`, and `buffer-cycle-coreaudio-summary.json` under the investigation directory.

The owner clarified that Safari probably displayed the same page, but its browser/tab session had been restarted. The buffer cycle therefore did not reproduce the original persistent failure state. The two driver corrections remain tested and signed but uninstalled, and this clean run is not validation of their effect on the reported clicks.
