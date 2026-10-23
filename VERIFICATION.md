# Verification — October 22, 2026

This is a chronological history. Early statements about an uninstalled driver and untested hardware are superseded by later dated additions. For further latency work, read the [current plan](Docs/LATENCY-PLAN.md).

## Passed locally

- C++/Objective-C++ build: AudioServerPlugIn, Core Audio bridge, device inventory and tests.
- SwiftUI app compiled for Apple Silicon.
- `core-tests` and `route-tests` passed in Release.
- Both test programs passed with AddressSanitizer and UndefinedBehaviorSanitizer.
- Bundle plists and shell scripts passed syntax checks.
- Local ad hoc signatures verified for the app and driver bundle.
- App opened through macOS. Matrix and channel list inspected; separate input/output fields tested with 37/21.
- Read-only inventory read actual Core Audio devices and channel names, including UFX Analog, ADAT and MADI and ZED Input channels.
- Latest UI reading: UFX III 94 inputs/94 outputs, 96 kHz; ZED-R16 18 inputs/18 outputs, 96 kHz.
- User's intended setup: UFX III as master, normally 96 kHz, ZED synchronized through ADAT. The final build's default rate was adjusted accordingly.

## Not verified

- Driver **not installed or loaded by coreaudiod**. In-process tests do not prove working HAL publication.
- No audio routed to/from the user's interfaces and no recordings made.
- Private aggregate with hidden bridge, microphone permission and Ableton behavior require live testing.
- No physical round-trip latency, bit transparency or DAW recording offset measured.
- No extended run, sleep or physical disconnection tests performed.

No RME/ZED settings, TotalMix, existing Aggregate Device or macOS default audio devices changed. No services, drivers or automated jobs installed.

## Addition: Follow clock master

Pre-start rate synchronization and a separate sync button implemented. The master rate is read; only selected physical slave interfaces with mismatching rates are written. The whole group is checked first. `rate-tests` exercises the policy with simulated reads/writes, including asynchronous confirmation, timeout and rejected changes. No actual rate changes performed on the user's interfaces. Changes during audio are not seamless: the engine is silenced and stopped.

## Addition: Dormant routing connections

Channel counts now limit only which stored connections reach the engine. Reducing counts deletes no routes. Complete routing is saved in the preset file. All four programs pass: `core-tests`, `route-tests`, `rate-tests` and new `preset-tests`. The Swift test uses the app's model and serialization to verify reduction → save/open → increase, and zero channels in one direction. The callback test verifies silence for removed active routes and audio after reactivation. These are in-process tests; equivalent behavior with an installed HAL driver and physical interfaces remains unverified.

## Addition: Automatic session saving

All five programs pass after adding `session-tests`. The new test instantiates the app's actual `Model` with an isolated temporary session file and no hardware inventory. It checks automatic saves on direct field/routing edits, restoration in a new model, dormant connections, 0/0 editing mode, empty interface selection, increasing counts before UI normalization, backup of a corrupt file and visible write errors. No termination signal or manual save is needed. The updated app was inspected in macOS and displays “Changes are saved automatically”. Full UI quit/restart with the user's routing remains unverified.

## Addition: Custom channel labels

All five programs pass. Session tests verify separate labels for identical channel numbers on different interfaces and in different directions, automatic restoration, preset export and removal without changing the other direction's label or routing. Presentation preserves original names. Older presets without label fields work. The app was restarted and the label editor opened and inspected through the accessibility tree and a screenshot. Test labels were not written to the user's session.

## Addition: Fixed matrix headers

The matrix now uses a shared NSScrollView for cells and two fixed header areas following scroll position on their respective axes. All five programs pass in the final build. Visually verified: horizontal scrolling to MADI retains DAW input row names on the left; vertical scrolling in the playback matrix to UFX ADAT/MADI retains DAW output column names at the top. An initial drawing bug painted backgrounds outside subviews; explicit clipping and bounded background fills fixed it. No routing or hardware settings changed during scroll verification.

## Addition: Hover highlighting and direct label editing

All five programs pass in the final build. Session tests verify channel selection in the label editor, separate virtual DAW labels, matrix row/column indices after scrolling, bounds checks and that hover highlighting does not change routing. Original names and custom labels are now drawn separately so truncation does not hide labels.

Visually verified: existing RE-201 label appears beneath ZED-R16 Input 1. Double-clicking that header opens the correct direction in the editor with RE-201 selected. The row, column, both headers and cell border highlight at the pointer position. The latest app build is open. User labels, routing and audio settings were unchanged during these UI checks.

## Addition: To Computer / From Computer and derived labels

All five programs pass. Channel headers, directions, count fields, channel list and errors now use To Computer/From Computer. The editor contains only hardware inputs/outputs. Session tests verify routing-derived labels, multiple destinations, updated hardware labels, fallback names, disconnection, dormant/reactivated channels, ignoring older virtual labels and selecting connected hardware on double-click.

App and driver built and signature-checked. The UI tool could read the older running build but rejected restart/close because the app had changed, even after reconnecting. The new UI therefore remains visually unverified in this round; the new build is in Dist/StudioPatch.app. No driver installed.

## Addition: Confirmation when deselecting interfaces

All five programs pass. Session tests verify confirmation for deselecting an interface with dormant routing, cancellation preserving interface and connections, confirmation removing only that interface's connections, and immediate selection/deselection without routing. A new app build is in Dist; the dialog was not interactively checked this round.

## Addition: Derived channel names in Core Audio

The visible device implements `kAudioObjectPropertyElementName` for input/output scopes, elements 1 through the current count. `kAudioDevicePropertyChannelNameCFString` is the same selector in the local macOS SDK. Names arrive through a separate plugin property and update without format/I/O reconfiguration; property notifications are sent only for changed elements. Name storage, locking and notifications occur outside the realtime callback.

All five programs pass. The core test uses the driver's actual property implementation for scope/element, size, CFString ownership, readability, fallback names, Unicode characters, quotes and backslashes, empty names, invalid counts and zero output channels. A simulated host verifies correct notifications, unchanged device ID during renaming with active I/O and persistent storage/reloading through initialization. Swift tests verify that published names derive from the same routing as the matrix, including multiple destinations and unconnected channels. App and driver built and signature-checked.

No driver installed or Core Audio restarted. Tests run in process; publication through the real HAL process and name display/updates in Ableton remain pending. The running app was not restarted this round.

## Addition: Unavailable selected interfaces

Last-known interface names, channel names/counts and rate are optional session/preset metadata. Availability always comes from current inventory by UID; old AudioDeviceIDs are not saved. Disconnected interfaces remain in the list and matrix with grey headers, labels and cells. Matrix hit testing and shared model setters allow only removal of connections for unavailable channels. The channel list uses the same setters and blocks unavailable choices. Deselect confirmation includes these interfaces and dormant routes.

All five tests pass. Extended session tests simulate inventory → disconnection → save/restart → edit → reconnection with a new runtime ID → deselection. They check the complete channel set including unrouted channels, labels and derived names, preset export, blocked new routing, permitted removal in both directions, dormant-routing warnings and matrix click blocking. No physical interfaces disconnected or user routing changed.

With user approval, the isolated UI test build opened with fictional interfaces and a separate session file. Visually verified: greyed-out interface with checked, clickable checkbox, all four input/output channels retained, saved labels and grey cells in both matrices. UI clicks and inspection of the test session verified removal of existing connections, blocking new and restored connections in both directions, and blocking disconnected input selection in the list. The warning names the interface. Cancel preserves it and routing; Disconnect removes it and its connections in both directions. No real interfaces or user settings changed.

## Addition: Automatic rate synchronization

The manual button is removed and the checkbox is named Follow clock master. Inventory compares selected interfaces and the app rate with the current master. Synchronization runs in a background task; a separate attempt series performs an initial attempt, three immediate retries and then five seconds after each failure. Deselecting or changing the master/interface selection cancels the previous series. Ongoing synchronous driver calls may need to finish. Routing stops before synchronization; name/channel publication and audio startup do not compete with the active automatic series. Errors appear as sidebar status.

All five tests pass. Retry policy tested for three immediate retries, continued five-second intervals and a fresh attempt series. Existing rate-tests cover driver errors, timeout and master changes through simulated calls. The full asynchronous UI flow and actual hardware rate changes remain unverified this round. The app was not restarted.

### Automatic transport margin

Automatic mode is the default, including older sessions, using four selected I/O buffers per direction. The engine payload contains the calculated margin; session/preset stores the manual value and automatic-mode choice separately. The UI shows samples and ms per direction and places manual adjustment under Advanced. Preset tests verify buffer/rate changes, engine payload, manual mode, restoration and older formats. All five suites passed; app and driver built and signatures verified. No new physical audio or latency measurements.

## Installed driver lookup corrected — October 23, 2026

The first actual HAL test returned system object (1) as the visible device's owner, not the plugin object. The app swallowed the property-read error, and an empty string caused Invalid channel count, sample rate or transport delay during name publication. Bridge now uses kAudioHardwarePropertyTranslateBundleIDToPlugIn with se.studiopatch.driver and reports property-read errors directly. Verified against the installed driver: correct plugin ID 58 and configuration 1 18 18 96000 256. All five suites pass. Corrected app opened without errors; Apply channel counts confirmed in UI. No driver reinstallation required. Audio startup and Ableton audio remain unverified.

## Startup deadlock — October 23, 2026

The user's hang report shows Model.start → SPConfigure → SetPropertyData → PatchPlugin.configure → Storage.WriteString, with an explicit deadlock between the driver's XPC thread and Core Audio change queues. Host storage moved to a separate serial dispatch queue with immutable snapshots and without taking the configuration lock. The same fix applies to channel names. The app's atomic session file remains primary storage. A new regression test makes host saving call back into the configuration getter and checks that two snapshots save in order. The core test has a 20-second timeout. All five suites pass; app and driver built and signatures verified. Not yet verified with the updated driver loaded in HAL. The install script's --replace preserves the previous identifier-validated driver outside the HAL directory. The user must update with administrator rights and restart before another audio test.

## Remaining PropertiesChanged deadlock — October 23, 2026

New actual driver sampling in /tmp/StudioPatch-driver-hang.txt shows Stream.SetIsActive → Object.NotifyPropertiesChanged → synchronous XPC reply from Core Audio. App sampling shows the main thread in Model.init → SPInventory → HAL device enumeration. The storage-call fix was insufficient: host notifications still ran on HAL's calling thread.

Local libASPL fix: PropertiesChanged and RequestDeviceConfigurationChange now dispatch from a separate serial host queue, with copied data and retained object lifetime. The separate storage queue remains. A regression test uses real Stream.SetPropertyData(IsActive) and a simulated host that waits for the setter to return; synchronous notification would deadlock. Existing name tests now wait for the notification queue.

All Core Audio calls from the Swift model moved to a serial background queue, including inventory, names, configuration, start/stop, status and synchronization. An ongoing operation blocks new polling/button calls; after five seconds, waiting status appears without pretending to cancel the call. Quitting attempts to stop the engine but waits at most two seconds for the audio server. Unknown device status is distinguished from successful inventory without StudioPatch. A new async Model test blocks inventory with a semaphore and verifies that MainActor continues, parallel polling queues no additional reads and status becomes known after release. All five suites pass; app/driver built and signatures verified. The updated driver requires installation and loading after restart before actual audio testing. No automatic audio-server or computer restart performed.

## Ableton buffer range too narrow — October 23, 2026

A read-only HAL probe of the installed driver showed StudioPatch ZeroTimeStampPeriod=128 and BufferFrameSizeRange=29..48, while UFX III and BlackHole reported period=16384 and range=29..4096. This explains why 32 was the only common power-of-two size in Ableton. The SDK's AudioServerPlugIn.h documents a minimum of 10923 frames for ZeroTimeStampPeriod. Both StudioPatch endpoints now use RingFrames=16384 for the advertised period and GetZeroTimeStamp quantization. Transport delay and I/O buffer size are unchanged; the clock period does not require filling an entire ring before reading.

Regression tests verify the minimum period, identical advertised periods, timestamps at period boundaries, shared seed and timebase. All five suites passed. Pre-fix CPU snapshot: Ableton about 199%, ZED driver 41%, coreaudiod 15%, RME 12%, StudioPatch app 1.3% (process percentages, not Ableton's audio-load meter). Ableton sampling shows active audio processing including plugins; no single cause of all CPU load identified. Actual new buffer range and CPU require verification after installation/restart. No driver reloaded during this investigation.

## Stable status layout and one stop button — October 23, 2026

The user's screen recording showed two overlapping stop buttons. Sidebar settings now have their own disabled group; the single start/stop button sits outside it and the overlay button is removed. Routine polling no longer shows a temporary status row. Operation status reserves height even when empty; audio status is limited to one line with monospaced digits so the cycle counter cannot change layout height. The five-second warning and serialized Core Audio calls remain.

All five tests passed. The async model test checks that routine polling is silent but still blocks overlapping native calls. App built and signature verified. The user's running app was not restarted; the new layout remains visually unverified there. This UI change requires no driver installation.

## Background service and automatic format changes — October 23, 2026

StudioPatchService is a separate signed executable in the app bundle. It continues independently of the panel window/process. The panel saves requests atomically; the service only reads the session and exclusively owns the engine. The panel reads timestamped status with device inventory. Start/Stop/Apply are removed from the UI, and routing/channels can be edited during operation. The service applies changes and retries automatically. Routing-only edits currently cause a brief transport restart, not a seamless snapshot switch.

Driver: HAL-scheduled changes on existing endpoint IDs, new streams and a shared session. Old/new rings stay silent during transition; readiness publishes only after both endpoint configurations are confirmed. Async completion callbacks do not take the plugin lock under the device lock. Abort leaves audio silent. A new timebase generates a new timestamp seed. AvailableNominalSampleRates and allowed stream formats come from the master within 8–384 kHz. Client nominal/stream-format requests publish to the service; it sets the master, then other interfaces, verifies rates, changes virtual configuration and starts transport. Acknowledgement uses compare/exchange so an old reply cannot erase a newer request.

The panel requests notification permission; the service sends notifications only when macOS grants it. Each error generates at most one notification until recovery. Errors appear in panel status without a modal. install-service.sh prepares login startup without sudo; the helper's single-instance lock prevents duplicate engines.

All six suites pass, including extended core-tests for active configuration, stable device ID, 4/2 and 1/0, preferred channel counts, 192 kHz, format lists and muted old rings. Scripts/test-runtime.sh builds the real Swift service/Model with a simulated native backend and runs it as a separate process: automatic startup without the panel, singleton behavior, route changes, silence on failure, automatic recovery and acknowledged client rate all pass. Test files are isolated from the user's session. This is not a physical audio test; actual HAL/Ableton verification, login startup and notifications require installation and user testing. The older running app and installed driver were unchanged.

## HAL registration of rate control — October 23, 2026

After user installation/restart, the service was active but reported needing a new driver. Installed and distributed driver SHA-256 matched (cb4b0a592577a58b95e045692061e49209e6fc12c0719b644d04ba5d0f06fa1d), ruling out missed installation. RatesProperty (sprt) implemented HasProperty/SetPropertyData but was missing from RegisterCustomProperty and hence HAL's CustomPropertyInfoList. Clients could not see it through Core Audio. It is now registered as CFString and can be read back. A new regression checks all six used custom properties in the HAL registry with correct types and reads the rate list. The native error now describes the missing property instead of claiming the correct version is absent. Installation/reloading is required before actual audio startup can be verified.

## Rate payload and restoration before HAL publication — October 23, 2026

Installed and distributed drivers had identical SHA-256 f8db7ebd0caf984d391123973dee4254884ed28a60f6c8eb3b70440443dd35aa. Error 1852797029 is 'nope'. UFX III reported seven rates: 32000, 44100, 48000, 88200, 96000, 176400, 192000. The long numeric text exceeded the server's conservative 256-byte UTF-8 allocation limit. RateWire now uses shorter lossless exponent notation when it saves space. A regression sends this exact UFX list through driver.SetPropertyData and checks all values and the CFString bound. A live probe of installed HAL accepted the list and returned masterRate=96000, requested=0.

After updating the service, both ZED and UFX synchronized to 96000. The next error was Request virtual configuration 'nope'. A read-only live probe showed Ready=0 and remaining default configuration 1 18 18 96000 256. Initialize restored saved configuration using asynchronous change requests for devices HAL had not yet published. Immediate host.RequestDeviceConfigurationChange rejection was also ignored, leaving the configuring flag set.

Restore during Initialize now temporarily detaches unpublished endpoints from the plugin hierarchy, configures them synchronously and reconnects them before Initialize returns. Runtime changes still use HAL's async mechanism. LibASPL explicitly aborts requests immediately rejected by the host. Regression tests verify that initial restore sends no configuration requests, Ready is true afterward, and runtime rejection clears pending state and allows retry. This driver change requires installation/restart, so actual audio startup cannot be confirmed in the same run.

## Format notifications (2026-10-23)

The background service now sends macOS notifications for successful sample-rate or exposed channel-count changes, and for failed attempts. Notifications include the requested rate, To/From Computer channel counts and selected hardware names. Success is sent only after configuration, engine startup and client-request acknowledgement complete. A pending format change survives partial failure so eventual recovery also reports success. Repeated failures for the same target are suppressed until recovery; ordinary routing edits and startup with an already matching format are silent. Notification submission errors are logged. Display remains subject to macOS notification permission and Focus settings.

Validation: all six CTest suites pass. The separate-process runtime integration test exercises actual Swift service decisions against the fake native backend, including silent matching-format startup/routing edits, one failed-format event across immediate retries, a recovery success event, and exactly one success for a client sample-rate request. Notification events are captured to an isolated test file instead of displaying system banners. Real macOS banner delivery and a live Ableton format change have not been exercised by this automated test.

## Live Ableton format test (2026-10-23 morning)

Ableton Live 12 Suite selected StudioPatch as both input (4 channels) and output (2 channels), with a 256-sample Ableton buffer. Changing Ableton from 96 kHz to 48 kHz updated StudioPatch, UFX III and ZED-R16 to 48 kHz with routing active and zero reported bad buffers. Selecting 96 kHz in StudioPatch then updated Ableton and both physical devices to 96 kHz. Playback/test tone stayed off. This confirms control/format propagation, not measured audio latency or dropout-free audio during transition.

The user reported no notifications for either transition. System Settings shows StudioPatch notifications enabled for Desktop and Notification Center. Service logs show notification settings fetched but the original authorization guard prevented submission. Diagnostic removal of that guard results in an explicit delivery error; notification delivery is under investigation.

Notification diagnostics: service authorizationStatus was 0 (notDetermined); submission and requestAuthorization both fail with UNErrorDomain code 1. A stable service code-signing identifier alone did not fix this. Notifications remain unverified/nonfunctional from the LaunchAgent. The local builds are ad-hoc signed; no valid certificate-backed code-signing identities were found by security find-identity. Repeated microphone permission prompts may be related to this signing setup, but that causal connection has not been verified from TCC logs.

A later frequency restore exposed competing panel/client rate requests: a retained panel request could override a pending driver request, preventing configuration readiness. Client rate requests now take priority and discard the stale panel request.

## Certificate signing and notification correction

The notification failure was resolved by signing the embedded service with identifier se.studiopatch.app, matching its enclosing app. macOS accepted format-changed notifications and the user confirmed a visible notification. Merely choosing a separate stable service identifier did not work.

The previous 'no valid identities' result was obtained inside the sandbox and was misleading. A permitted unsandboxed Keychain query found Apple Development and Developer ID identities. The app and service are now signed with the same Apple Development certificate (local development team), and their designated requirements are identical and certificate-based rather than code-hash-based. Scripts/signing-identity.txt holds only the public certificate fingerprint; private keys remain in Keychain. build.sh uses this identity by default and fails rather than silently falling back to ad-hoc signing. STUDIOPATCH_SIGNING_IDENTITY can explicitly override it on another developer's Mac. Certificate replacement requires updating that configuration.

Initial transition from ad-hoc signing may require permission again. Persistence across subsequent builds is to be checked. Six CTest suites and the runtime integration tests pass. The driver installed in Core Audio is unchanged; the packaged driver is signed but no driver installation was performed.

Certificate transition verification: TCC explicitly reported failure to match the former ad-hoc cdhash against the new Apple Development designated requirement. The visible app now explicitly requests audio capture permission when notDetermined. At 08:44:45, TCC logged AUTHREQ_PROMPTING for se.studiopatch.app / Microphone. Final user consent and subsequent engine-start/rebuild persistence verification remain pending; the engine was waiting in AudioDeviceStart. Do not claim microphone persistence fully tested until this consent and a subsequent restart complete.

Final permission verification, 08:47–08:49: user granted the certificate-based microphone prompt. TCC recorded Allowed (User Consent) for both the panel and old running signed service. Restarting into the newer signed service (PID 6608) reused Allowed (User Consent), without a new AUTHREQ_PROMPTING event, and routing resumed at 96 kHz with zero reported bad buffers. A live Ableton 96→48 kHz change produced Notification accepted: format-changed from that signed service at 08:48:32. Ableton was restored to 96 kHz. The user had already confirmed seeing a notification after the identifier correction. Certificate-based permission persistence across these two signed builds is verified; no machine reboot was required or tested.

### Hot-unplug inventory isolation (2026-10-23)
- Hardware discovery no longer fails when StudioPatch plug-in configuration cannot be read.
- Ignore non-alive devices and isolate per-device C++ property-read failures during hot unplug.
- Missing selected hardware is reported before virtual-driver availability errors.
- Live verification with disconnected ZED-R16: checked device retained, greyed out, last-known 18 inputs/18 outputs shown, missing-device status identifies ZED-R16.
- Runtime regression exercises inventory updates during retry backoff, retained selection, and automatic reconnect recovery using simulated hardware.


## Latency handoff — 2026-10-23

Read-only review and Core Audio property probe completed. Physical RTL, recording offset and long-duration dropout measurements remain unperformed. No buffer/rate/driver changes were made for this investigation. The full stage plan, acceptance gates, rollback workflow and blank run record are in `Docs/LATENCY-PLAN.md` and `Docs/LATENCY-RUN-TEMPLATE.md`; observations are in `Docs/LATENCY-REVIEW-2026-10-23.md`. The read-only probe source is retained in `Tools/latency-probe.cpp`. Source checksums identify the reviewed code, not the installed driver binary. No optimization or scheduled continuation is in progress.


## 2026-10-23 — Directional latency reporting, version 0.1.1

Implemented and installed Sync Source device/stream latency plus separately measured StudioPatch input/output delay. Two internal hidden-bridge timing channels identify actual sample timing; a 100 ms control timer publishes directional HAL properties with notifications and session-generation validation. Visible stream latency is zero to avoid duplication.

All six CTest suites and the runtime integration suite passed. Independent physical UFX III output 3 → input 3 captures verified 20 windows across 48/96 kHz, 32/64-frame engine buffers and service/format restarts. Largest observed per-direction discrepancy was 1.128 frames. Reported sums were 1324/1580/724 frames for the respective configurations; physical timestamp-referenced delays were consistently 5 frames larger, matching direct UFX hardware residuals. No hardware correction or stability optimization was applied. Original session restored exactly in JSON meaning, service active at 96 kHz / 32-frame I/O / 64-frame margin.

See [the measurement record](Docs/LATENCY-MEASUREMENT-2026-10-23.md) for the methodology, raw artifact locations, installed backup and limits. Individual DAW compensation and long-duration stability remain unverified.


## 2026-10-23 — Direct transport, version 0.2.0

Installed the hardware-clocked shared-memory transport and authenticated launchd broker, replacing the live hidden-bridge path. Sync Source callbacks remain independent of slower interfaces; Apple handles optional secondary drift correction. Correct directional latency and safety offsets use Core Audio's configuration-change mechanism. Input margin spans at least one physical callback, output margin is independent, and the UI displays the new margins.

At engine buffer 32 and client buffer 256, physical UFX cable RTL is **665 → 729 frames at 96 kHz (+0.667 ms)** and **601 → 649 frames at 48 kHz (+1.000 ms)**. Directional reports agree within approximately 1.4 samples in final observations; the hardware's five-frame residual stays separate. Thirty-second waveform checks, a matched four-worker CPU load comparison, 64/512 client buffers, service restart and 96↔48 transitions passed. Optional ZED correction did not slow UFX; 449,280 passive ZED input samples were bit-identical through StudioPatch. Seven CTest suites and the runtime integration tests passed. Earlier gap-producing candidates were rejected.

[Full evidence and limitations](Docs/LATENCY-DIRECT-2026-10-23.md). This is not an all-interface or long-soak stability certification. Final configuration restored to 96 kHz / 32 engine frames with original routing and synchronization choices; later user preset changes preserved.
