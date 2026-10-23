# StudioPatch — development prototype 0.1

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


> **Current handoff, 2026-10-23:** [Latency plan](Docs/LATENCY-PLAN.md), [baseline review](Docs/LATENCY-REVIEW-2026-10-23.md) and [measurement record](Docs/LATENCY-RUN-TEMPLATE.md). Latency optimization and physical loopback measurements have not started. Work resumes only at the user's request.
>
> **Historical notice:** Several sections below describe older prototypes and are not current operating instructions. Routing now runs automatically in a background service; the app is a control panel. Individual synchronization locks, built-in named presets and a persistent active preset with unsaved changes are available. The app and service use certificate signing. Manual Start/Stop, file-based preset buttons, global Follow clock master and automatic ad hoc signing no longer apply. Read the new plan's current-state, build and recovery sections before continuing.

A local macOS app and virtual Core Audio driver for freely ordered channels from multiple audio interfaces. Intended for UFX III (including MADI channels from the M-1610 Pro) and ZED-R16.

**Status: buildable prototype, not a verified replacement for the RME driver.** Audio logic and the channel model are tested in process. Core Audio loading, Ableton operation and physical round-trip latency remain to be verified. Opening the app produces no audio. All routes are disconnected on first launch; subsequent launches restore the last session.

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
- The engine uses a private Aggregate Device. The app does not modify the user's existing Aggregate Device or default devices.
- Follow clock master monitors the master's rate and automatically synchronizes other selected physical interfaces when they differ, even without the virtual driver installed. The master is never changed. A failed attempt is followed by three immediate retries, then five seconds between attempts. Status appears in the sidebar. Clearing the checkbox stops further attempts; an ongoing driver call may need to finish. Changing the master or selected interfaces starts a new attempt series. Active routing stops before synchronization and does not restart automatically.
- Missing channels or failed rate synchronization block startup. Device/format changes during operation silence outputs and stop routing at the next status check.

## Architecture and latency

```text
UFX / ZED inputs → private Core Audio aggregate → routing engine
    → internal hidden bridge output → capture time buffer → StudioPatch input → Ableton

Ableton → StudioPatch output → playback time buffer
    → internal hidden bridge input → routing engine → UFX / ZED playback channels
```

The driver is an AudioServerPlugIn built with libASPL. The hidden bridge and visible device share a timebase, but capture and playback have separate buffers. Channel counts can therefore differ, and playback is not automatically mixed into recording. No file, network or IPC audio transport connects the app and driver; Core Audio carries audio through the internal bridge.

This prototype prioritizes a correct channel model and safe behavior over minimum latency. Audio callbacks do not allocate memory or wait on mutexes. Time buffers use atomic samples and return silence for missing or overwritten frames. Buffers are touched during initialization, but memory pages are not yet locked; production hardening remains.

The transport margin is automatic by default, following the selected I/O buffer with four buffers **per direction**. Current samples and milliseconds per direction are shown at the selected sample rate. Under **Advanced**, automatic mode can be disabled and the margin chosen manually; the manual value is preserved while automatic mode is active. Older sessions without this setting use automatic mode. Defaults are 96 kHz, 64 I/O samples and thus a 256-sample margin, with UFX III preselected as master when present. At 96 kHz, the combined transport margins are 5.33 ms, **in addition to** other signal-path stages. This is a calculation of the selected margin, not measured round-trip latency. The UI allows smaller margins; startup requires at least two actual I/O buffers per direction. For example, 32 I/O samples and a 64-sample margin give a calculated combined transport margin of 1.33 ms at 96 kHz. Stability in this mode is unverified.

UFX and ZED can share an ADAT clock with drift compensation disabled on physical interfaces. In this version, the virtual bridge uses the computer's timebase with Core Audio drift compensation enabled. **The prototype is therefore not guaranteed to be bit-transparent and is not a driver clocked directly by UFX.** A later optimization could tie the virtual clock to hardware timestamps; this requires separate implementation and measurement.

The driver reports its own transport margin but does not yet forward all underlying hardware/aggregate latency to the DAW. Automatic recording compensation may therefore be incorrect. Do not use it for timing-critical recordings before physical loopback measurement and recording-offset verification.

## Build and open

Requires Xcode/Command Line Tools, CMake and macOS 14 or later. The included build targets Apple Silicon on this Mac.

```sh
./Scripts/build.sh
open Dist/StudioPatch.app
```

The build creates the app, `.driver` and read-only `patch-inspect` tool in `Dist`. It installs nothing. Without the driver, interfaces can be inventoried, matrices edited and presets saved; audio-start controls are disabled.

The build uses local ad hoc signing if `STUDIOPATCH_SIGNING_IDENTITY` is unset. It is not notarized. Passing signature checks does not prove that Core Audio loads the driver. Do not change SIP or macOS security settings to bypass loading errors; investigate logs and signing instead.

## Installation and first hardware test — not yet performed

1. Close audio applications and save ongoing work.
2. Review `Scripts/install-driver.sh`. It installs only `StudioPatch.driver` in `/Library/Audio/Plug-Ins/HAL` and refuses to overwrite an existing installation. To update, use `sudo ./Scripts/install-driver.sh --replace`; the previous StudioPatch driver is saved under `/Library/Audio/StudioPatch Backups` before replacement. Restart the computer after updating.
3. Run `sudo ./Scripts/install-driver.sh`, then restart the computer. The script does not restart the audio server automatically.
4. Verify that **StudioPatch** appears in Audio MIDI Setup. Open the app. Confirm that both physical interfaces show the correct rate and that ADAT is actually locked/synchronized. The app cannot verify ADAT lock for you.
5. Set the desired input/output counts and rate. Click **Apply channel counts** while the DAW audio engine is off. Then select StudioPatch as both input and output in Ableton. Channel changes may require updating Ableton's Input/Output Config.
6. Select both interfaces, the correct clock master and your routes. Leave drift compensation off on ADAT-synchronized interfaces. **Follow clock master** reads the master's rate and sets other selected interfaces to match. The app first checks support, writability and whether another application is using the interface. An asynchronous change must be confirmed within two seconds per interface. There is no manual sync button; mismatches are detected by the inventory every two seconds and synchronized in the background. Check channel selections afterward: some channels may disappear at higher rates. If a change partially fails, some interfaces may already have switched; an error is shown and there is no automatic rollback. The app does not change clock sources or ADAT lock.
7. Start with one low-level signal and a larger transport margin. Grant microphone access if macOS asks. Click **Start routing**. The app generates no startup signal.
8. Test recording and playback separately, then together. Verify that playback is not heard on recording channels without intentional external routing.
9. Measure a physical output→input loopback with both direct RME and StudioPatch at identical rates and buffers. The difference measures added latency. Also check the DAW recording offset.
10. Reduce margin and buffer gradually; then run for at least 30 minutes, checking glitches, disconnection, stop/start and reopening Ableton.

UFX outputs in the app are its **software playback channels**. TotalMix still determines how they reach physical outputs. ZED return selections are also controlled by the mixer's own settings.

To uninstall, close audio applications, run `sudo ./Scripts/uninstall-driver.sh` and restart. The script removes only a bundle with identifier `se.studiopatch.driver`.

## Tests and remaining work

`core-tests` covers asymmetric channel counts, format validation, duplex isolation, exact time-buffer offsets, silence for missing/stale frames, a shared virtual timebase, an active client during reconfiguration and concurrent reads/writes across buffer wraparound.

`route-tests` uses the actual engine callback with synthetic UFX, ZED and bridge buffers to check reordering, both directions, silent unused outputs and silence after layout changes.

`rate-tests` covers never writing to the master, delayed confirmation, already synchronized interfaces, rejection of busy/read-only/incompatible interfaces, timeouts and master changes during synchronization. Tests use simulated driver calls. Actual UFX/ZED rate changes have not yet been tested. Changes during audio still stop routing; automatic synchronization then attempts to follow the master.

`preset-tests` exercises the app's actual Swift model: independent input/output reductions, saving/opening dormant connections, restoring counts, zero channels in one direction, explicit disconnection and older preset formats. Engine JSON receives only active connections. `route-tests` also checks that removed active routes are silenced without residual samples and can be reactivated in both directions.

Remaining before production use: actual HAL loading/reconfiguration, signed distribution, microphone permission, verification of the private aggregate with the hidden bridge, device changes and sleep, extended testing, RTL/DAW compensation measurement and high-channel-count performance. The app must remain open during routing. Routing can be changed after stopping; changes during audio are not implemented.

## Sources and licenses

- libASPL is pinned to `633e0f70203edd87d320fc5a3cae901e1363aac5` and included unchanged in `Vendor/libASPL`. Its MIT and Apple licenses are stored there.
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
