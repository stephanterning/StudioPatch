# StudioPatch — development prototype 0.2

## Open-source repository

StudioPatch is an experimental macOS virtual audio device and routing control panel. The original StudioPatch code is licensed under the [GNU Affero General Public License, version 3 only (AGPL-3.0-only)](LICENSE).

For development, use macOS 14 or later, Xcode with its command-line tools, CMake and Python 3. Provide your own certificate-backed signing identity via `STUDIOPATCH_SIGNING_IDENTITY` or a local `Scripts/signing-identity.txt` file. That file, build products and private keys are excluded from Git.

From the repository root:

```sh
export STUDIOPATCH_SIGNING_IDENTITY="Apple Development: Your Name (IDENTIFIER)"
export STUDIOPATCH_BUILD_DIR="$PWD/build"
bash Scripts/build.sh
bash Scripts/test-runtime.sh
```

Build products are written to `Dist/`. Building does not install the driver or restart audio services. Read [BACKGROUND-RUNTIME.md](BACKGROUND-RUNTIME.md) before installation and [Docs/LATENCY-PLAN.md](Docs/LATENCY-PLAN.md) before latency work. The historical development notes below include superseded behavior; the handoff notice identifies those limitations.


> **Current handoff, 2026-10-23:** The direct transport in 0.2 replaces the hidden audio bridge. Sync Source channels use hardware-clocked shared memory; independently clocked secondary devices use Apple drift correction on their own paths. See [direct-path measurements and limits](Docs/LATENCY-DIRECT-2026-10-23.md). Correct directional reporting and signal integrity are requirements alongside the 1 ms added-round-trip target.
>
> **Historical notice:** Several sections below describe older prototypes and are not current operating instructions. Routing now runs automatically in a background service; the app is a control panel. Individual synchronization locks, built-in named presets and a persistent active preset with unsaved changes are available. The app and service use certificate signing. Manual Start/Stop, file-based preset buttons, global Follow clock master and automatic ad hoc signing no longer apply. Read the new plan's current-state, build and recovery sections before continuing.

A local macOS app and virtual Core Audio driver for freely ordered channels from multiple audio interfaces. Intended for UFX III (including MADI channels from the M-1610 Pro) and ZED-R16.

**Status: hardware-tested development prototype.** Core Audio loading and physical UFX round-trip latency are verified for the configurations in the measurement record. Long-duration stability and other hardware paths remain to be qualified. Opening the app produces no audio. All routes are disconnected on first launch; subsequent launches restore the last session.

## Implemented features

- One visible device, `StudioPatch`, with independent input and output counts: 0–128 per direction, at least one direction active. For example, 37 inputs/21 outputs, without padding to a power of two.
- Selected interfaces that disappear remain greyed out in the interface list and matrix. Names, all channels and labels come from the last saved inventory, including after restart and in exported presets. Existing connections can be removed, but new connections to/from the interface are blocked in both the matrix and channel list. The checkbox can still be cleared. When the same device UID returns, its current channels are used and normal editing resumes. The list refreshes every two seconds while routing is stopped. Older presets without stored channel information must be opened once with the interface available to acquire it; otherwise unknown interfaces show their UID and a missing-channel-information status.
- Deselecting an interface with stored input or output connections requires confirmation. The warning names the interface and includes dormant connections. **Cancel** preserves the interface and routing; **Disconnect** removes the interface and its connections. Interfaces without connections are deselected immediately.
- Virtual-device channel names in Core Audio use the derived label, such as `RE-201`. Unconnected channels use `To Computer N` or `From Computer N`. Without a custom hardware label, the hardware channel name is used; multiple destination names are joined. Changes are published automatically after a short delay and on apply/start. Names are sent separately from audio configuration, with Core Audio notifications, and require no device restart. If a channel count has not yet been applied, name publication waits for the matching layout. Names are also persisted by the driver. This requires the new driver build; actual display and updates in Ableton remain to be verified.
- Two independent audio paths and matrices: hardware input → To Computer, and From Computer → hardware output. No automatic loopback from From Computer to To Computer.
- One source per destination, with unrestricted fan-out. No summing, gain or DSP in this version.
- Matrix headers behave like frozen panes: row names stay on the left during horizontal scrolling and column names stay at the top during vertical scrolling. Each header follows its cells on the other axis. This applies to both routing directions and custom labels.
- Real channel names come from the drivers, including UFX Analog, Mic, AES, ADAT and MADI. UI and preset channel numbers start at **1**.
- Hovering over a cell highlights its row and column, including headers, and gives the cell a clear border. Highlighting does not change connections.
- Double-click a hardware header to open **Labels…**, scroll to the channel and focus its label field. For To Computer/From Computer, this opens the connected hardware channel; with multiple destinations, it selects the first in interface channel order. No editor opens for an unconnected channel.
- **Labels…** edits custom hardware input/output labels. To Computer and From Computer cannot have independent labels: they are derived from connected hardware channels and update with routing or hardware labels. Missing labels fall back to hardware channel names. Multiple destination names are joined, with duplicates shown once. Older custom virtual-channel labels are ignored. Matrix labels appear on a separate cyan line below the original name. They supplement the interface and channel name in the matrix and list, for example `UFX III · Analog 9 — Vocal microphone`. Labels are stored by device UID, direction and channel, even without routing or when unused. They are included in automatic session saves and exported presets. Clear a field to remove its label. Original hardware names remain unchanged; exposed StudioPatch names are derived from these labels and routing.
- Device connections use Core Audio UIDs, not temporary device numbers. JSON presets can be opened and saved.
- Every change is saved automatically to `~/Library/Application Support/StudioPatch/last-session.json` using atomic replacement. Channel counts, all routing including dormant connections, selected interfaces, clock master and buffer/rate choices are restored at launch. A 0/0 editing state can be saved but cannot start as an audio device. An empty interface list or temporarily missing interfaces are not replaced with defaults on restore. Routing does not start automatically. Save errors appear in the app; an unreadable session file is backed up before replacement after the next edit. **Save preset…** remains available for named presets.
- In either direction, a source can feed multiple destinations. Each destination has at most one source; a new selection replaces its previous connection. There is no summing or mixing. Presets with multiple sources for one destination are rejected, even if some connections are dormant.
- Channel counts and stored routing are separate. Reducing exposed channel counts makes their connections dormant: they are not sent to the engine and produce no audio. Increasing the counts restores them, including after saving and reopening a preset. The channel list marks dormant output connections. Explicitly selecting a new connection or “Not connected” replaces the previous connection to that destination.
- Channel-count/rate changes are rejected while the virtual device is in use. Stop routing and disable the DAW audio engine first.
- The Sync Source path uses independent physical callbacks. Private aggregates are used only for secondary interfaces that need Apple drift correction. The app does not modify the user's existing Aggregate Device or default devices.
- Follow clock master monitors the master's rate and automatically synchronizes other selected physical interfaces when they differ, even without the virtual driver installed. The master is never changed. A failed attempt is followed by three immediate retries, then five seconds between attempts. Status appears in the sidebar. Clearing the checkbox stops further attempts; an ongoing driver call may need to finish. Changing the master or selected interfaces starts a new attempt series. Active routing stops before synchronization and does not restart automatically.
- Missing channels or failed rate synchronization block startup. Device/format changes during operation silence outputs and stop routing at the next status check.

## Architecture and latency

```text
Sync Source input → physical I/O callback → shared capture timeline → StudioPatch input → DAW
DAW → StudioPatch output → shared playback timeline → physical I/O callback → Sync Source output
```

The selected Sync Source supplies the sample/host clock. Its path copies native Float32 samples without gain, mixing or resampling. Capture and playback have independent tagged atomic storage; absent or overwritten frames become silence. The panel is independent of the background service. An authenticated launchd broker shares memory between the signed service and the sandboxed AudioServerPlugIn. IPC occurs during configuration, never in an audio callback. The libASPL I/O wrapper still serializes audio operations, but StudioPatch uses a separate lifecycle lock for client start/stop. Its timestamp implementation does not use libASPL’s mutable start/stop clock; the entire driver stack is not lock-free.

Other clock-locked interfaces have separate physical callbacks and safety-offset allowances. A secondary device with drift correction enabled uses a private Apple aggregate with Sync Source as its clock reference; only that secondary's routes pass through it. StudioPatch does not implement its own sample-rate converter. The user's existing aggregates and default devices are unchanged.

Visible input/output latency is the Sync Source's device + maximum stream latency plus the corresponding StudioPatch margin. Safety offsets match Sync Source and are reported separately. Core Audio configuration changes apply timing updates before startup. At 32-frame engine I/O, margins are 32 input + 32 output frames at 96 kHz, and 32 input + 32 output frames at 48 kHz. Both directions retain at least one engine buffer after load tests found short playback corruption with a 16-frame output margin. At 48 kHz this is 1.333 ms added round trip, above the original 1 ms target; a lower-latency mode is not yet qualified. Larger engine buffers increase both margins. These are engine buffers; a DAW's 256-frame buffer remains a separate setting. Advanced settings show the current margins. Old preset margin fields are retained for compatibility but no longer control this transport.

Other interfaces can have different path latency; global reporting intentionally refers to Sync Source. Independently measured hardware error remains separate. The [measurement record](Docs/LATENCY-DIRECT-2026-10-23.md) distinguishes measured duplex RTL, timestamp-referenced delay and HAL reports, and lists unverified configurations. Brief tests are not a long-duration stability qualification.

## Build and open

Requires Xcode/Command Line Tools, CMake and macOS 14 or later. The included build targets Apple Silicon on this Mac.

```sh
./Scripts/build.sh
open Dist/StudioPatch.app
```

The build creates the app, `.driver` and read-only `patch-inspect` tool in `Dist`. It installs nothing. Without the driver, interfaces can be inventoried, matrices edited and presets saved; audio-start controls are disabled.

The build requires a persistent certificate-backed identity and never falls back to ad hoc signing. It is not notarized. Passing signature checks does not prove that Core Audio loads the driver. Do not change SIP or macOS security settings to bypass loading errors; investigate logs and signing instead.

## Installation and hardware testing

1. Save work and close audio applications before replacing the system driver.
2. Run `sudo bash Scripts/install-transport.sh` to install the signed shared-memory broker and its service signing requirement. Review the script first; it creates the `se.studiopatch.transport` LaunchDaemon.
3. Run `sudo bash Scripts/install-driver.sh --replace` for an update, or omit `--replace` for the first installation. Previous drivers are preserved under `/Library/Audio/StudioPatch Backups`. Restart macOS to load the new driver; installation does not restart Core Audio automatically.
4. Register the background service with `bash Scripts/install-service.sh` as your normal user. See [BACKGROUND-RUNTIME.md](BACKGROUND-RUNTIME.md). Open the app and grant microphone access when requested.
5. Select physical interfaces, Sync Source and routes. Leave drift correction off only when interfaces share a hardware clock; StudioPatch cannot verify an external ADAT lock. The service automatically applies routing and rate changes.
6. Select StudioPatch in the DAW and test input/output separately. Compare a physical loopback against direct Sync Source at the same sample rate and DAW/client buffer. Preserve hardware correction separately from StudioPatch delay.

UFX outputs in the app are its **software playback channels**. TotalMix still determines how they reach physical outputs. ZED return selections are also controlled by the mixer's own settings.

To uninstall, close audio applications, run `sudo ./Scripts/uninstall-driver.sh` and restart. The script removes the identified StudioPatch driver and its transport broker, preserving user presets and backups.

## Tests and remaining work

`core-tests` covers asymmetric channel counts, format validation, duplex isolation, exact time-buffer offsets, silence for missing/stale frames, a shared virtual timebase, an active client during reconfiguration and concurrent reads/writes across buffer wraparound.

`route-tests` uses the actual engine callback with synthetic UFX, ZED and bridge buffers to check reordering, both directions, silent unused outputs and silence after layout changes.

`rate-tests` covers never writing to the master, delayed confirmation, already synchronized interfaces, rejection of busy/read-only/incompatible interfaces, timeouts and master changes during synchronization. Tests use simulated driver calls. Physical UFX/ZED rate changes and their exact tested configurations are recorded in `Docs/REVIEW-ACTIONS-2026-10-23.md`. Changes during audio still stop routing; automatic synchronization then attempts to follow the master.

`preset-tests` exercises the app's actual Swift model: independent input/output reductions, saving/opening dormant connections, restoring counts, zero channels in one direction, explicit disconnection and older preset formats. Engine JSON receives only active connections. `route-tests` also checks that removed active routes are silenced without residual samples and can be reactivated in both directions.

Remaining before production use: actual HAL loading/reconfiguration, signed distribution, microphone permission, verification of the private aggregate with the hidden bridge, device changes and sleep, extended testing, RTL/DAW compensation measurement and high-channel-count performance. The app must remain open during routing. Routing can be changed after stopping; changes during audio are not implemented.

## Sources and licenses

- libASPL is pinned to `633e0f70203edd87d320fc5a3cae901e1363aac5` with local cycle-timing and opt-in lifecycle-lock changes in `Vendor/libASPL`. Its MIT and Apple licenses are stored there.
- [libASPL](https://github.com/gavv/libASPL)
- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Aggregate properties and channel order follow the documentation in Xcode's `CoreAudio/AudioHardware.h`.

The included source code is local and installs no services or scheduled tasks.

## Background-engine test version

Close the older StudioPatch app and audio applications before updating. Install the new driver with `sudo Scripts/install-driver.sh --replace`. Then run `Scripts/install-service.sh` as your regular user, without sudo. Restart the computer. The service starts at login with the saved configuration; the app can be opened and closed as a control panel.

Routing and channel counts are applied automatically, possibly causing a brief audio interruption. Rates exposed by StudioPatch come from the clock master (within 8–384 kHz). Change the rate in Ableton to request a change on the selected interfaces. Rejection or timeout silences transport and displays the error in the panel; allow system notifications if desired. Actual compatibility with client format changes must be verified with the installed test driver.

Unregister the background service with `launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/se.studiopatch.runtime.plist"`. Then remove that specific plist file to disable login startup. Opening the app starts the service again.

### Local signing

The build uses the certificate fingerprint in `Scripts/signing-identity.txt` and requires its private key in the user's Keychain. On another development computer, set `STUDIOPATCH_SIGNING_IDENTITY` or update the fingerprint. No private key is included in the project. The app and embedded engine use the same certificate and signing identifier (`se.studiopatch.app`) for a shared permission identity. The build does not automatically fall back to ad hoc signing. The first transition from older local builds may require renewed audio-access consent.

### Broker identity and login sessions

The broker authorizes the signed StudioPatch service for the current `/dev/console` user and Apple's Core Audio daemon. Background users in fast user switching do not receive service access; run the engine in the active console login. This is a current product limitation.

`Scripts/build.sh` captures the service's designated signing requirement in `Dist/service.requirement`. After changing the signing identity, reinstall the broker with the matching requirement as well as the app and driver. Replacing only the app can leave a correctly signed service that the old broker rejects. The broker retains the shared-memory mapping for the current session; existing peer mappings remain independent when a new session replaces it.


### Review implementation notes (2026-10-23)

`RuntimeController.swift` owns the service state machine independently of SwiftUI. The service build excludes `App.swift` and `Matrix.swift`; integration tests execute the actual controller. Session-file replacement and HAL inventory events trigger refreshes. A one-second heartbeat remains for status, client rate requests and recovery; inventory has a five-second fallback. Physical latency/stream-latency changes invalidate the engine and republish timing during restart. There is no 100 ms latency polling timer.

HAL initialization publishes the visible device immediately with silent transport while an asynchronous worker connects to the broker. The `spts` property reports `connecting` or `ready` and the attempt count. Acquisition retries with bounded backoff. Driver connections re-register their existing mapping after broker interruption, preserving storage identity. Audio callbacks perform no XPC or signature checks. The production factory creates one endpoint; the legacy engine is compiled only for explicit test builds and direct sessions allocate no legacy sample rings.

Custom control writes (`spcf`, `spnm`, `sprt`, `sprq`, `splt`) require the broker-registered PID for the current generation held by a live XPC connection whose signature and console-user identity the broker validated. Standard HAL sample-rate requests remain available to audio clients. The broker revokes the registration when that connection dies; the driver revokes it on broker interruption. Install all components together.

Advanced diagnostics show each secondary interface’s calculated input/output latency difference relative to Sync Source. These are reported hardware/safety-offset estimates, not measurements of the analog path. Secondary host/sample alignment is monitored continuously. A deviation exceeding `max(32, callbackFrames/4)` for at least three callbacks spanning 20 ms latches a mute and warning for that secondary until service restart. This detects timestamp drift or jumps; it is not a direct read of ADAT lock status. Fast paths remain unaligned to slower hardware. A common aligned mode would intentionally add latency and is not part of this release.

The complete finding-by-finding disposition and hardware evidence are in `Docs/REVIEW-ACTIONS-2026-10-23.md`. Tagged storage is retained after profiling; no high-water-only validity scheme is used.

### Bounded hardware captures

`Tools/run-hardware-capture.py` runs the built `latency-capture` tool as the current user. It requires explicit device UID, input/output channel and result prefix. Use an isolated loopback: the selected output receives the test signal. Output 0 disables playback. For example, with the existing UFX channel-3 loopback:

```sh
python3 Tools/run-hardware-capture.py --capture build/latency-capture \
  --uid RMEUSBDevice-131-24243649 --input 3 --output 3 \
  --seconds 30 --buffer 256 --load 0 --prefix work/capture-001
```

The runner refuses an existing result prefix, limits duration to 300 seconds, and terminates its own capture process if it exceeds the requested duration by 20 seconds or Core Audio stays above 80% of one CPU core for ten seconds. Cancellation also terminates the capture. Partial files and a failure report remain available. Successful acquisition still needs timestamp analysis and waveform comparison; it is not itself an audio-integrity pass.

These measurements and user-service updates need no administrator password. Do not perform Core Audio or broker fault injection on this working workstation: earlier system-restart qualification caused global enumeration/CPU failures. Use simulated failures for recovery tests and the bounded runner for normal hardware audio. Additional disruptive system qualification requires a separate controlled environment.

When a launch-agent plist exists, the panel starts that registered job (bootstrapping it if necessary). It reports a launch failure instead of creating an unmanaged fallback process. Keep the plist's executable in a persistent location; temporary staging directories may disappear at reboot.

### Bounded service recovery

Plug-in lookup falls back to enumerating individual bundle IDs when HAL's bundle translation fails, skipping stale unrelated objects without caching their IDs. Structured Core Audio errors reach the runtime controller. A bad-object failure persisting for at least three attempts and ten seconds requests a fresh service process image; a control task still blocked after 30 seconds requests the same recovery independently of the blocked worker. Only StudioPatch replaces itself. No system service is restarted.

A persistent `recovery-attempt.json` in the application-support directory permits at most one automatic replacement per ten minutes. Another failure inside that interval stops the service with successful exit so launchd does not loop. Invalid or unwritable recovery state also stops safely. The stopped reason remains readable beyond the ordinary snapshot freshness limit. This is a circuit breaker, not a guarantee that every hardware or HAL fault is repairable. After correcting the underlying device problem, reopen the control panel to start the managed service. Do not delete the limiter file to force repeated recovery attempts.

Stopped/reconfiguring engines clear obsolete timing diagnostics. Invalidated or unexpectedly stopped engines rebuild through the existing serialized controller. A secondary clock fault stays muted: automatic unmuting without evidence of clock lock is deliberately excluded. Synthetic runtime tests cover transient format failures, disconnect/reconnect, invalid clock recovery, persistent HAL errors, blocked calls and the cross-process restart limit. They do not force the real computer to sleep or disrupt the live broker.
