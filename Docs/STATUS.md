# Project status

## Bundled Ableton label tool — 2026-10-25

The signed app now includes Tools → Update labels in Ableton next to Labels…. A compiled helper implements the existing Live 12 adapter without requiring Python or Xcode at runtime. The window detects preferences files, remembers a selected version or custom path, and displays the current preset's full device name. Live-running checks, missing-file/device instructions, permission errors, verified backups and atomic writes are included; channel activation and unrelated settings remain unchanged.

All ten CTest suites passed. Native adapter tests compare output with the Python adapter and exercise backups, naming rules, malformed layouts, missing files/devices, Live starting during preparation and concurrent preferences changes. The existing CLI dry-run also passed. Live UI checks verified file selection/persistence, the full preset-name instruction and moved-file errors using an isolated fixture. A read-only preview of the real Live 12.4.7 preferences reported labels already current; real Ableton preferences were not modified. The actual macOS permission-denied prompt and an end-to-end Live restart were not exercised. The panel and signed helper were installed while preserving the existing service binary and running process.

**Version 0.2.0. Experimental, hardware-tested development prototype.**

StudioPatch has been developed and tested on its author's studio setup, and its architecture has been through a full review (all 19 findings addressed or explicitly accepted). It has **not** been qualified as a general release: it has been tested on one Mac with one combination of interfaces, there are no signed or notarized builds, and several failure modes have only been tested in simulation.

## Preset identity and labels — 2026-10-24

The working tree implements per-preset virtual UIDs and Core Audio-owned channel labels, including a copy choice on Save current as new. The updated driver/app must be installed together. The signed package was installed and the Mac restarted on 2026-10-24. The updated driver and runtime are running.

Setting, clearing, copying and channel-name notifications passed live Core Audio probes on disposable private aggregates in both directions. Driver/model tests cover identity changes, retiring the old endpoint, no dirty marker for labels, stable identities on reopen and partial-copy failures. Service integration tests cover UID changes at unchanged audio format and display-name changes without an engine restart.

Native StudioPatch label retention across repeated preset disappearance/reappearance passed on 2026-10-24: two 46-input/40-output presets (legacy UID and a new per-preset UID) retained every input and output label when switched back and forth twice. Independent Core Audio inventory reads were compared, and the original active preset was restored. A known manual label on the legacy UID also survived the Mac restart. Audio MIDI Setup displayed the copied labels under the new device identity. Shrink/grow, reboot retention for newly created preset UIDs, and DAW identity refresh remain unverified. Label edits now save on focus loss, Return, Done or Escape; focus-loss and Done saves were verified against live Core Audio, and all eight test suites passed. Explicit destroy/recreate of a **private aggregate** did not retain labels; that experiment does not prove how HAL treats a native driver endpoint. See [verification details](LABEL-VERIFICATION.md).

## Physical input source labels — 2026-10-25

The signed panel in `Dist/StudioPatch.app` now supports source labels for interface inputs routed to To Computer. Labels are shared across presets in a separate StudioPatch registry, default to the interface/channel name, and appear green in vertical headers. Each Source row compares against its destination's Core Audio name; a red-label click updates that destination and verifies it by readback.

All eight CTest suites and the runtime integration script passed. Model tests cover cross-preset/relaunch persistence, fallback names, no configuration/automatic-name changes, independent fan-out destinations, readback and write failures, stale selections and corrupt storage. Matrix hit testing covers the second line after scrolling. Live UI verification on the existing BlackHole setup passed source editing, Done/focus-loss save, vertical-header double-click, red-to-green after a matrix click, and leaving another destination of the same source red. Independent Core Audio reads confirmed only the selected destination changed. All original Core Audio names, session and presets were restored after the test; no test source aliases remain. Only the panel was updated; the existing service binary and process were preserved. UFX-specific live label editing has not yet been exercised.

## Physical output labels — 2026-10-25

The signed panel now includes Interface outputs, shared across presets and stored alongside input aliases with direction-aware keys. From Computer shows hardware labels in Routing, green/red according to their match with the connected Core Audio output name. Clicking a red Routing label writes that From Computer channel and verifies by readback. Source and the vertical header display the actual Core Audio label; Source is not a sync target for outputs. Every row sharing the virtual source then recomputes its own comparison. Empty aliases and text equal to the current interface/channel name resolve automatically, including after focus loss or Done.

All eight CTest suites and the runtime integration script passed. Tests cover independent input/output labels at the same UID/channel, output persistence across presets and relaunch, fallback following physical-name changes, shared virtual sources, output-direction writes/readback, pending state on all affected rows, moved/disconnected/dormant output routes, and matrix text/hit targets. Existing input failure/readback tests exercise the shared update path. The matrix layout was rendered and inspected. Live panel verification passed editing/saving a temporary BlackHole output label, mismatch status, and clearing back to an automatic name with no stored override. All source-label, preset/session and Core Audio data were checked against their pre-test snapshots afterwards. The existing service binary and process were preserved. Actual From Computer alias writes remain covered by model tests and the earlier Core Audio output write/clear probes; this UI check did not change live output aliases.

## Tested setup

- Apple Silicon Mac, macOS 14 or later.
- RME UFX III over USB 3 as Sync Source, including MADI channels from an RME M-1610 Pro.
- Allen & Heath ZED-R16 as a secondary interface, clock-locked over ADAT.
- Ableton Live 12 Suite as the DAW.

Other interfaces should work if they offer Float32 streams at the selected sample rate, but nobody has tried yet. Reports are welcome.

## Verified on hardware

- The driver loads in Core Audio; the StudioPatch device appears with the configured channel counts and names.
- Audio routing in both directions, fan-out, silence on unrouted channels.
- Added latency and directional latency reporting at 48 and 96 kHz with a 32-sample engine buffer (see [LATENCY.md](LATENCY.md)).
- Sample-rate changes from Ableton and from the panel propagate to the Sync Source and the locked interface (96 ↔ 48 kHz).
- Routing changes while audio is playing, without disturbing other channels.
- Extra clients starting and stopping while a recording client runs.
- Restarting the background service; audio returns automatically.
- A selected interface being disconnected: kept greyed out, reported as missing, picked up again on reconnect.
- Microphone permission persisting across rebuilds signed with the same certificate; notifications delivered from the background service.
- Signed service accepted by the broker; unsigned clients rejected.

## Tested only in simulation

These paths are covered by automated tests with a simulated audio backend, but have not been exercised on real hardware. Deliberately breaking Core Audio on a working studio machine was ruled out after earlier experiments caused a system-wide Core Audio failure.

- Recovery after the broker is restarted while audio is running.
- Sleep and wake.
- A secondary interface actually losing clock lock.
- Automatic self-restart of the service against a real, persistently failing Core Audio connection.

## Not yet tested

- Long-duration soak tests (hours).
- Sample rates other than 48 and 96 kHz, and engine buffers other than 32 with the current transport.
- Very high channel counts under load.
- Other interfaces as Sync Source, other DAWs, Intel Macs.

## Known limitations

- **48 kHz misses the 1 ms target:** 1.333 ms added round trip with a 32-sample engine buffer, accepted for stability.
- **Graph changes interrupt audio.** Changing channel counts, sample rate, Sync Source, engine buffer or the set of interfaces restarts the engine briefly. Routing-only edits are seamless.
- **Latency reporting refers to the Sync Source.** Routes from secondary interfaces can have a somewhat different real latency.
- **A secondary clock fault stays muted** until the service is restarted. This is deliberate.
- **Active console user only.** With fast user switching, only the user at the screen can run the engine.
- **The service runs from your clone.** Moving or deleting the repository breaks the installed background service.
- **No mixing, gain or DSP.** Each destination has exactly one source.
- **Build-it-yourself only.** You need your own Apple signing certificate.

## Open issues

- On one occasion, repeated Core Audio restarts during testing left `coreaudiod` using a full CPU core and failing to enumerate devices until reboot. StudioPatch's own processes were idle at the time. The root cause is unknown; StudioPatch now contains the failure (bounded retries, at most one self-restart per ten minutes) but does not claim it is fixed.
- After one reboot, a secondary interface failed to start and the service then saw persistent "bad object" errors from Core Audio until it was restarted. A lookup fallback and bounded self-restart now handle this path; the original trigger is not established.

The finding-by-finding review disposition is in [history/REVIEW-ACTIONS-2026-10-23.md](history/REVIEW-ACTIONS-2026-10-23.md).

## Label dialog layout — 2026-10-25

The label dialog has a fixed 900 × 640-point size. The channel picker has its own row below its caption, and help/status areas reserve the same height across tabs, saving and error states so the picker and list do not move. Help text wraps within its reserved area; long error text is available in full on hover. The channel list uses the remaining height. The signed panel was rebuilt and checked in the live Core Audio and interface-output tabs; the saving state was also rendered with an isolated fixture. The existing audio service process and binary were preserved.

## Interface label edit correction — 2026-10-25

Reproduced a live UFX edit reverting on focus loss: after a synchronous local save removed the draft, the TextField binding read the old name captured in its row and could write it back. The binding now resolves the saved name from the current model. Regression checks cover old input/output row snapshots, and all eight CTest suites passed. Live UFX input focus-loss save, output Return save, persistence in the separate label registry, tab switching and clearing to automatic names passed. Temporary test aliases were removed and the registry was compared with its original contents. Only the signed panel was replaced; the audio service remained running.

## Bidirectional routed label copying — 2026-10-25

Both labels in a mismatching Source/Destination pair are orange and clickable. A click copies the selected value to the opposite side. Core Audio-to-interface copies update only the selected physical channel’s shared alias; interface-to-Core-Audio copies retain verified readback. Matrix hit areas/tooltips and accessible channel-list buttons support both sides. Automated coverage includes both directions, shared channels, independent input/output keys, persistence, unavailable/busy states, corrupt storage and scrolled hit targets. All eight CTest suites passed. The matrix was rendered and inspected; live channel-list copying from Core Audio to UFX input/output aliases passed, and those temporary changes were cleared and the original registry verified. Channel-list menus now reuse the channel choices per refresh after profiling repeated full-port enumeration with the 46-input/40-output UFX preset; live switching between both lists responds normally. Only the signed panel was replaced; the existing audio service stayed running.

## Matrix-only routing view — 2026-10-25

Removed the Channel list switch, alternate routing view and its dedicated label controls. The routing matrix is now the sole routing view in both directions. Device-order help, accessibility text and user documentation no longer refer to the removed view.

All ten CTest suites passed. The signed panel was installed and both routing directions were checked live; the Channel list switch is absent. The audio service binary and running process were preserved.

## Collapsible routing banks — 2026-10-25

Both matrix axes now support inferred groups from original interface channel names and sequential numbers. AES stays individual. Runs over 16 channels have nested banks of at most 16; virtual To/From Computer channels use independent 16-channel banks. Collapsed intersections aggregate existing connections, with counts in tooltips; clicking a filled or empty grouped cell expands the relevant axes without editing routes. Destination summaries retain connection and mismatch counts, while individual rows retain their exact source names. Fold preferences are separate UserDefaults state, shared by hardware UID/direction across presets and scoped to preset UID for computer channels. Group bands and grouped cells expose accessible actions.

All eleven CTest suites passed, including the new matrix-group suite covering inferred UFX/ZED banks, gaps, AES exclusion, nested banks, stable IDs under device renaming/reordering and shorter inventories, original-index routing and label hits after folding/scrolling, fan-out, offline routes, busy-state browsing and persistence. Live UFX/ZED UI checks passed folding both axes, eight-connection aggregate expansion in both routing directions, empty-cell expansion, MADI parent/child folding and persistence over panel restart. Expanded and collapsed layouts were inspected. Final session contents and the saved preset/interface-label files were verified unchanged by these UI operations; the service stayed running with the same binary. Sample-rate inventory changes and disconnected banks were exercised with fixtures rather than changing live audio hardware.
