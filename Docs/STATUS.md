# Project status

## Simplify configuration failure handling — 2026-10-27

Implemented in source; **not installed**. One planned simplification round on top of `f827958`, following explicit owner decisions instead of further point fixes. See the [implementation hand-over](history/AUDIO-CHANGE-IMPLEMENTATION-2026-10-27.md#simplification-round).

- A change that fails after Core Audio applied it leaves audio off with a message, keeps the device published and is retried while audio is off. The automatic return to the previous configuration (including across presets) was removed.
- A change Core Audio rejects before applying it keeps the old engine running. If StudioPatch wrote the Sync Source in that attempt, it sets the Sync Source and locked interfaces back once to the running rate; a rate changed by something else is never set back.
- Sample rate: a client or panel request is only forwarded; the StudioPatch device keeps reporting its running rate until it is reconfigured, so a refused or unconfirmed rate leaves the DAW and the panel at the previous rate with a message. Locked interfaces follow the rate the Sync Source reaches; one changed elsewhere is reported as not in sync and not set back while audio runs.
- System notifications are sent only for problems (disconnection, failed change, audio off, refused rate, locked interface out of sync), once per problem. Successful changes, publication and preset switches appear only in the status line.
- The unused `SPFollowMaster` path, `ratePlan`/`applyRates` and `rate-tests` were removed.
- Review follow-up: an own Sync Source write is remembered until its change resolves, so a rejection after an unreadable readback still undoes it. Hardware rates are set only when the rate changes, the Sync Source rate changed or audio starts, so an unrelated change no longer sets back a locked interface changed elsewhere.

All ten CTest suites and the runtime integration suite (36 scenarios plus the HAL-import check) passed. The driver change (client rate requests no longer change the reported rate) needs a driver install and a Mac restart together with the service; the `4359` shared-memory protocol from `3d6a847` still requires matching driver, broker and service. Nothing has been exercised on UFX III/ZED-R16 hardware.

## Follow-up review of `5183ca7` — 2026-10-27

Implemented in source; nothing installed or tested on physical audio hardware. Fast configuration/publication follow-ups now last only one second, then use the normal heartbeat without cancelling the operation or stopping audio. A restored endpoint keeps its own display name and notification name. See the [latest review handover](history/AUDIO-CHANGE-IMPLEMENTATION-2026-10-27.md#review-of-5183ca7) for regression evidence and the explicit, unchanged choices around post-commit start failure and restoration across preset identities.

Verification: **11/11 CTest suites and 37/37 runtime scenarios plus HAL isolation passed (38 checks).** The two requested regression cases fail against `5183ca7`; the first-clock timing case also failed in the baseline run. Production service and panel linked locally but were not launched.

## Follow-up review of `3d6a847` — 2026-10-27

Implemented in source, not installed. Preset identity changes now leave the replacement absent until its clock is available, with named withdrawal/return notifications. HAL rejection can undo a recorded hardware-rate write after checking the current rate; a refusal never stops the old engine. Pending HAL completion gets a 25 ms follow-up, padding never shrinks during an engine lifetime, and fan-out names follow effective preset order. See the [follow-up handover](history/AUDIO-CHANGE-IMPLEMENTATION-2026-10-27.md#follow-up-review-of-3d6a847) for evidence, limitations and the remaining live-I/O hardware risk.

Verification for this follow-up: **11/11 CTest suites and 33/33 runtime scenarios plus HAL isolation passed (34 checks).** Both requested regression assertions fail against `3d6a847`; the corrected controller passes. The driver publication assertion also fails on the old driver. Production service and panel linked locally but were not launched.

The earlier sections below describe prior revisions.

## Keep the engine through pending configuration — 2026-10-27

Implemented after review of `74cef6e`; **not installed or tested on physical audio hardware**. See [implementation and review handover](history/AUDIO-CHANGE-IMPLEMENTATION-2026-10-27.md) for reproduction steps, evidence and remaining risks.

- Removed the preflight/stop/rollback sequence. The real configuration request runs while the old engine remains active. HAL rejection, a failed control write and missing rate information no longer stop/restart that engine.
- A pending request is confirmed by transport generation and configuration, without repeated submissions after a readback failure. New preset edits wait for its resolution. Physical disconnection can still withdraw the device while HAL is processing the change.
- A successful rate write followed by unreadable readback no longer restores a guessed rate. A subsequent confirmed read leads to the matching engine configuration. A refused request that leaves the current graph unchanged does not restart it.
- Actual Sync Source callback lengths update transport padding immediately. An unknown startup buffer size cannot leave a permanent undersized margin. Buffer-property changes alone no longer trigger rebuilds; channel-layout changes still do.
- If the new engine fails to start after HAL applies the format, the previous configuration is restored only after a fresh matching rate read. Unknown rates never authorize restoration.
- Shared padding is now atomic. `SharedTransport::Magic` changed: **driver, broker and service must eventually be updated together**. None were installed here.

Final local verification: 11/11 CTest suites and 28/28 runtime scenarios plus the HAL-import isolation check passed. The production service and panel linked against the real bridge; no production binary was launched.

The entries below describe earlier investigation stages; this section and the new handover supersede their preflight, rollback and buffer-baseline behavior.

## Remove automatic audio stops from the control path — 2026-10-26

Implemented in source; **not installed**. This addresses every finding of the audit below. It also fixes further stop paths found in a second review and during implementation; see the [review and hand-over](history/AUDIO-STOP-REVIEW-2026-10-26.md).

Only confirmed physical disconnection and an applied rebuild now stop running audio. The rest of the behavior:

- Settings, label, inventory, rate-query, status, broker-authorization, driver-lookup and publication failures are shown in the status line while audio keeps running.
- Disconnection is confirmed by Core Audio's UID lookup and alive flag before stopping.
- The control watchdog, bad-object counter, `ServiceRecovery` and `recovery-attempt.json` are removed. StudioPatch never restarts itself; launchd still restarts the service after a crash, as before. The panel has a **Restart audio service** button while audio is off, and the same command in the StudioPatch menu.
- The direct engine has no property listeners and no global invalidation flag. A malformed block skips only itself. Each heartbeat checks stream layout; the current implementation updates buffer timing in callbacks and republishes latency without rebuilding.
- Routes to unavailable channels stay silent and are listed instead of preventing start. A secondary that cannot open or start is reported and left out.
- For rate changes, the Sync Source is set first and locked secondaries follow the rate it actually reaches. Refusals are reported, the engine runs at the actual rate and the request is acknowledged.
- Sync lock also works while audio runs. A locked secondary found at another rate is set back without a restart. If it refuses, routing continues with a status message. A secondary whose own sample counter restarts is realigned instead of writing to a stale timeline.
- Publication is retried on later heartbeats without stopping the engine.
- A change that fails while the Sync Source still runs at the previous rate restarts the previous configuration and is reported as not applied, without retry loops. A failed acknowledgement of a rate request is retried without applying the change again. A failed rate query keeps the current rate.
- Control failures that can be detected beforehand (broker authorization, plug-in, Sync Source) defer a change without stopping audio. An unreadable Sync Source rate is never reported as reached. A buffer size unknown at start is learned rather than treated as a change. Optional timing confirmation can no longer fail a start. After a restored configuration, status, labels and sync lock use the running rate. See the [2026-10-27 hand-over](history/AUDIO-STOP-HANDOVER-2026-10-27.md#resolution).
- Only stream layout and buffer size trigger a rebuild; latency and safety offsets are republished. Unreadable device metadata does not fail a start. Toggling sync lock does not rebuild.
- In the driver, a client rate request and a pending or rejected configuration change no longer disable the current session.
- `LegacyEngine` and its `route-tests` suite were removed, together with the listener helpers they depended on.

All eleven CTest suites passed (including the new `bridge-fault-tests`), and so did the isolated runtime integration suite (24 scenarios plus the HAL isolation check). New runtime scenarios: an unreadable session, a channel-name write failure, a rate-query failure, a driver lookup failure and an inventory metadata omission while running cause no stop, no withdrawal and no new process image. Further scenarios cover publication failure after start, a locked secondary refusing a rate, a Sync Source refusing a client request, a locked secondary changed elsewhere being set back (or reported) without stopping audio, a rate-control error during sync lock that stays visible, a failed rate query with outdated inventory, a failed acknowledgement, and a rejected change that keeps the previous configuration. Direct tests check a malformed block followed by a valid block, realignment after a secondary counter restart, sync lock excluded from the graph comparison, and route compilation with a missing channel, a missing interface and an already-used output. Core tests check that a client rate request and a rejected configuration change leave the session ready.

Not yet done: no signed build was made, nothing was installed and the running service was not restarted. The service change takes effect after `Scripts/build.sh` and a service restart. The driver change requires installing the driver and restarting the Mac. The restart button and menu command were built and linked but not exercised in the running panel. Not exercised on hardware: secondary start failure, unavailable-channel routes after a real rate change, publication retry against real HAL timing, settings changes in an interface's control panel while routing, and the heartbeat hardware comparison over a long session.

## Audit: remaining automatic audio stops — 2026-10-26

**Addressed by the entry above.** At the time of this audit the implementation did not satisfy the no-automatic-muting design requirement. Removing clock gates did not remove the broader stop behavior in the control path. This audit inspected the direct callback, HAL driver, runtime controller, bridge, recovery process, shared storage, routing handover and applicable libASPL I/O path. It changed no product code or installed binary. The design requirement is now explicit in CONTRIBUTING.md.

| Finding | Trigger and outcome | Evidence |
|---|---|---|
| Broad exception handler stops healthy audio | An unreadable session, channel-name write error, or control/query failure reaches `RuntimeController.runtimeTick`'s catch and calls `AudioWorker.stop()`. The endpoint stays published. | Reproduced session JSON and label-write failures in the real service with a fake backend and connected devices. `Sources/RuntimeController.swift:194–199`. |
| Inventory omission stops before disconnection is confirmed | `SPInventory` can omit an alive device when a metadata read fails. The controller stops I/O before `SPSetDeviceAvailable` performs its UID/alive check. If that check finds the hardware connected, it rejects withdrawal but audio has already stopped. | Reproduced the inventory-omission / still-connected response sequence. `Sources/RuntimeController.swift:103–107`, `Sources/Bridge.mm:410–442,643–651`. |
| Control watchdog can terminate the service permanently | A control operation lasting 30 seconds invokes recovery even if audio callbacks remain valid. If the ten-minute restart budget is used, unreadable, or cannot be written, the service calls `_exit(0)`, suppressing launchd restart. It does not withdraw the endpoint first. | Reproduced a blocked control operation with a recent recovery reservation: process exited and the fake endpoint remained available. `Sources/RuntimeController.swift:74–79`, `Sources/Service.swift:12–31`, `Sources/ServiceRecovery.swift`. |
| Any watched property notification invalidates the whole engine | Device-alive, rate, buffer, safety-offset, latency or stream-layout notifications set one global `invalidated` flag without first comparing values. The next callbacks return silence before control code can decide whether a rebuild is needed. | Static trace of the unconditional listener block and callback gate. `Sources/Bridge.mm:159–166`, `Sources/DirectEngine.hpp:62,268–276`. |
| One malformed block latches all subsequent callbacks off | Buffer validation sets the same global invalidation flag. Even the next valid block is skipped until the runtime rebuilds the engine; the flag is shared by every interface. | Reproduced in a native direct-callback fixture: one malformed block followed by a valid block remains silent. `Sources/DirectEngine.hpp:62,69–72`. |
| Rejected reconfiguration leaves the old session disabled | `configure` sets the current session's `ready=false` before the HAL accepts the change. Its abort callback clears only the pending-configuration flag, leaving the old usable session disabled. The read/write handlers then skip audio. | Reproduced the shared configuration path with the existing rejected-HAL-change fixture: ReadyProperty remains 0. `Sources/Driver.cpp:65,98,477–490`. |

Further start/reconfiguration gates remain: the direct engine rejects reported latency above 131072 frames and requires the HAL safety-offset report to match within two seconds (`DirectEngine.hpp:46,279–288`); bridge configuration waits five seconds for HAL readiness; selected/locked hardware rate changes wait two seconds for acknowledgement. These can prevent audio from starting while hardware remains connected. A requested format change may require waiting for the actual new format, but a timeout must not silently turn an otherwise usable previous configuration into an indefinitely selectable, silent endpoint. A routing handover timeout likewise reaches the broad exception handler above; its interim table may already have released moving capture routes (`DirectEngine.hpp:161–177`).

No remaining sample-amplitude, distortion or inferred-clock-quality detector was found in the active signal path. The old `LegacyEngine` is behind `STUDIOPATCH_ENABLE_LEGACY` and is not the installed engine. Basic buffer bounds, actual absent frames, unavailable shared memory and unsupported sample representation are technical inability to copy a sample, not permission to disable other working audio. Session retirement after a user-selected preset switch and deliberate physical-disconnection withdrawal have separate purposes.

Reproduction artifacts are in `work/audio-stop-audit/`: the audit fake backend, build script, Python runner, `results.json`, native callback fixture and shared driver-configuration fixture. The service fixture was verified not to link any HAL query/listener/device entry points. No physical interface was disconnected and the real service was not restarted for this audit. These were defects at the time of the audit, not fixes. Corrections should remove the coupling from non-audio failures to audio shutdown and preserve the last working configuration, without adding another layer of automatic recovery policies.

## Remove clock-based audio gates — 2026-10-26

The recorded ZED-R16 incident was a software latch: the secondary callback compared driver sample/host timestamps with a fixed startup alignment, required a deviation above `max(32, callbackFrames/4)` for three callbacks spanning at least 20 ms, then returned before copying any audio until the service restarted. The saved trigger was −32.795953 samples at 96 kHz (about −0.342 ms); a later peak was −188.343975 samples. The virtual device remained published because no physical member was missing. The hardware reportedly indicated Sync. There is no historical callback trace to establish why those driver timestamps diverged. Restarting the service cleared the latch and the user confirmed audio returned.

Removed the latch, secondary timestamp-age gates, master prediction-error invalidation, driver clock-age audio gates, and rejection of unlocked secondary rate mismatches. Timestamp values are diagnostics only. A backwards master sample counter is translated forward without stopping callbacks. Physical removal still withdraws the public endpoint. Buffer/layout validation and tagged missing-frame silence remain requirements for valid memory access and sample delivery, not inferred clock-lock policies.

The panel, service and driver must be updated. The broker protocol and shared-memory layout are unchanged. The driver update needs a Mac restart; rebuilding or restarting the service alone cannot replace the copy already loaded in Core Audio.

All eleven CTest suites and the isolated runtime integration suite passed. Regression tests replay the recorded trigger and larger positive/negative deviations while asserting sample delivery in both directions, test master counter reset without I/O invalidation, verify old/future host timestamps do not gate the HAL data path, and retain missing-hardware withdrawal/reconnect checks. Physical cable removal has not been performed during this change.

The updated panel and service are installed in `Dist/StudioPatch.app`, and the service was restarted once to activate them. Live status reports active routing at 96 kHz / 32 frames, zero buffer errors, and diagnostics without mute fields. The updated panel's diagnostic-only text was verified. After explicit installation approval, the user completed the administrator-authenticated install and restarted the Mac. Post-reboot verification on 2026-10-26 confirmed that the installed driver matches the tested binary (SHA-256 `88cb73d4230c531e7a1c66c4f31d739521bfffd3d19938ddc92b2acdc6f9dcf1`), both app and driver signatures verify, and launchd started the updated service at login. A fresh runtime snapshot shows the expected preset endpoint, active routing at 96 kHz / 32 frames, zero buffer errors, and no mute-latch fields. Timestamp deviations remain diagnostic. Session, preset and interface-label contents match their pre-update backups. This verifies installed binaries and software state; no additional physical unplug or acoustic measurement was performed.

## Device availability follows preset hardware — 2026-10-26

Implemented in source and local build. Every interface selected in the active preset is required, including unrouted members. Hardware loss withdraws the virtual endpoint from Core Audio; startup and preset changes with missing hardware leave it unpublished. The same preset UID is published again only after configuration, hardware I/O and a fresh master clock are ready. The service confirms the public HAL list and sends one named removal/availability notification per transition. Preset identity changes use the same notification path. Format changes and generic audio errors retain the existing published-device behavior.

The plug-in remains discoverable and controllable without a public endpoint. Applied latency/safety-offset reads no longer depend on a device ID. Retired endpoints reject new clients and return silence to existing readers. A second physical UID/alive check distinguishes metadata read failures from actual removal. Driver and service must be updated together; the broker and shared-memory layout are unchanged.

All eleven CTest suites passed, with affected suites rerun after the final changes. The isolated runtime integration suite also passed, including one-time notifications, hot unplug during retry backoff, reconnect, an unrouted missing secondary, offline preset changes, failed startup without publication, offline service startup, format failure without withdrawal, and bounded service recovery. Driver tests cover public UID removal/return, alive/device-list notifications, stale-client rejection and silence, names/UID preservation, property authentication, and timing configuration while unpublished.

The signed app, driver and broker were installed on 2026-10-26, and the service was registered for the next login. Installed binaries match the build and signature verification passed. The old driver is backed up at `/Library/Audio/StudioPatch Backups/previous.LFp5F6/StudioPatch.driver`; session, presets and interface-label files retain their pre-install hashes. The existing service and Core Audio were not restarted: a Mac restart is required to activate the matching new driver/service. Live HAL enumeration, macOS notification banner delivery and physical unplug/reconnect have not been exercised with this build. No separate Ableton UI test is required for this change.

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
- Large secondary timestamp deviations with uninterrupted capture/playback, including the recorded ZED incident values; master counter reset without stopping I/O.
- Audio continuing through settings, label, rate-query, driver-lookup, inventory-metadata and publication failures, and refused sample rates.

## Not yet tested

- Long-duration soak tests (hours).
- Sample rates other than 48 and 96 kHz, and engine buffers other than 32 with the current transport.
- Very high channel counts under load.
- Other interfaces as Sync Source, other DAWs, Intel Macs.

## Known limitations

- **48 kHz misses the 1 ms target:** 1.333 ms added round trip with a 32-sample engine buffer, accepted for stability.
- **Graph changes interrupt audio.** Changing channel counts, sample rate, Sync Source, engine buffer or the set of interfaces restarts the engine briefly. Routing-only edits are seamless.
- **Latency reporting refers to the Sync Source.** Routes from secondary interfaces can have a somewhat different real latency.
- **A secondary interface that cannot start is left out until the next rebuild.** The status line names it. Any configuration change, reconnecting the interface or **Restart Audio Service** in the StudioPatch menu tries again.
- **Clock configuration belongs to the user.** Timestamp deviations and unlocked rate mismatches do not mute routing. StudioPatch cannot infer hardware clock lock from driver timestamps.
- **Active console user only.** With fast user switching, only the user at the screen can run the engine.
- **The service runs from your clone.** Moving or deleting the repository breaks the installed background service.
- **No mixing, gain or DSP.** Each destination has exactly one source.
- **Build-it-yourself only.** You need your own Apple signing certificate.

## Open issues

- On one occasion, repeated Core Audio restarts during testing left `coreaudiod` using a full CPU core and failing to enumerate devices until reboot. StudioPatch's own processes were idle at the time. The root cause is unknown; StudioPatch bounds its own retries but does not claim the failure is fixed.
- After one reboot, a secondary interface failed to start and the service then saw persistent "bad object" errors from Core Audio until it was restarted. A lookup fallback now handles the plug-in lookup. The service no longer restarts itself. If this recurs, the status line shows the Core Audio error and **Restart audio service** in the panel restarts it. The original trigger is not established.

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
