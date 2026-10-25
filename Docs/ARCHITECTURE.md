# Architecture

This document describes how StudioPatch 0.2 works. It is written for developers who want to understand or change the code. For day-to-day use, see the [user guide](USER-GUIDE.md).

## Components

StudioPatch consists of four programs that work together:

| Component | Language | Runs as | Responsibility |
|---|---|---|---|
| `StudioPatch.app` | Swift / SwiftUI | The logged-in user, only while open | Control panel. Edits the configuration, saves it, and shows status. Closing it does not stop audio. |
| `StudioPatchService` | Swift + Objective-C++ | Per-user LaunchAgent `se.studiopatch.runtime` | The audio engine. Owns all physical audio I/O, applies routing and format changes, handles sample-rate requests, and sends notifications. Embedded in the app bundle. |
| `StudioPatch.driver` | C++ (libASPL) | Inside Apple's `coreaudiod` | AudioServerPlugIn that publishes the virtual device named **StudioPatch** that DAWs see. |
| `StudioPatchBroker` | C++ | Root LaunchDaemon `se.studiopatch.transport` | Authenticates the service and Core Audio, then hands both of them the same shared-memory region. Never touches audio samples. |

A small read-only command-line tool, `patch-inspect`, prints the current Core Audio inventory as JSON.

## Signal path

```text
          ┌──────────────── StudioPatchService (user) ────────────────┐
Physical  │ physical I/O callback ──► shared capture timeline ────────┼──► StudioPatch.driver ──► DAW input
interface │ physical I/O callback ◄── shared playback timeline ◄──────┼─── StudioPatch.driver ◄── DAW output
          └───────────────────────────────────────────────────────────┘
                          ▲ shared memory mapped once, during configuration,
                          │ through StudioPatchBroker (XPC, root)
```

- **Sync Source path.** The interface selected as Sync Source runs its own physical I/O callback. That callback publishes the interface's sample/host clock, which becomes the virtual device's clock. Native Float32 samples are copied straight into or out of shared memory, with no gain, mixing or resampling.
- **Clock-locked secondary interfaces.** Other interfaces that share the hardware clock (for example via ADAT or word clock) run their own callbacks and copy samples the same way. Extra safety offsets are accounted for per device.
- **Drift-corrected secondary interfaces.** An interface with *Drift correction* enabled is placed in a private Apple aggregate device with the Sync Source as clock reference. Only that interface's routes pass through the aggregate; Apple's drift correction resamples them. StudioPatch has no sample-rate converter of its own.
- **Storage.** Capture and playback use independent, tagged atomic sample storage. Frames that are missing, stale or overwritten are read as silence, so a stalled writer can never replay old audio. Every service start gets fresh storage and a new generation number.
- **No IPC in the audio callbacks.** XPC, signature checks, file I/O and allocation happen only on control threads. The libASPL I/O wrapper still serializes audio operations, so the stack as a whole is not lock-free.

The service never modifies user-created aggregate devices or the system default audio devices.

## Control path

```text
StudioPatch.app ──writes──► last-session.json ──watched by──► StudioPatchService ──► Core Audio + driver properties
StudioPatch.app ◄──reads─── runtime-status.json ◄──writes──── StudioPatchService
```

1. The panel is the **only writer** of the session file. Every edit is saved immediately with atomic replacement.
2. The service watches the session directory and Core Audio device notifications. A one-second heartbeat handles status, client sample-rate requests and retries; device inventory has a five-second fallback refresh.
3. The service compares the desired configuration with what is running:
   - **Routing-only change:** new immutable routing tables are swapped in at a block boundary. Audio keeps running and the DAW sees no format change.
   - **Anything else** (channel counts, sample rate, interface set, Sync Source, engine buffer): the transport is muted, the Sync Source and locked interfaces are set to the target rate, the virtual device is reconfigured through Core Audio's `RequestDeviceConfigurationChange` when its format or timing changes, and the transport restarts. Expect a brief audio interruption.
4. The service writes a timestamped `runtime-status.json`. The panel treats a snapshot older than 12 seconds as "service not responding".

When the panel opens, it starts the registered LaunchAgent (`launchctl kickstart`, bootstrapping it if needed). It never spawns an unmanaged copy of the service when a LaunchAgent is registered. A process lock (`runtime.lock`) guarantees a single engine.

### Driver properties

The service talks to the driver through custom Core Audio properties on the virtual device. The important ones:

| Selector | Purpose |
|---|---|
| `spcf` | Virtual device configuration (channel counts, rate, buffer). |
| `spnm` | Routing-derived default channel names. HAL manual aliases take precedence. Applied without reconfiguring audio. |
| `spdn` | Preset device display name, independent of its stable UID. |
| `sprt` / `sprq` | Rates the Sync Source supports / a sample-rate change requested by a DAW. |
| `splt` | Input and output latency reports, bound to a transport generation. |
| `spts` | Transport status (`connecting`/`ready`) and connection attempts. |
| `spdr` | Shared-memory transport registration. |

Writes to these properties require the broker-registered process ID of the currently authenticated service. Standard HAL sample-rate requests from DAWs remain open to all clients.

## Sample rates and clocking

- The Sync Source's available sample rates (limited to 8–384 kHz) become the rates the virtual device offers.
- A rate change can come from the panel or from a DAW changing the StudioPatch device's rate. DAW requests take priority over an older panel request.
- Each secondary interface has a **sync lock**. Locked interfaces are set to the Sync Source rate. Unlocked interfaces are never changed; if their rate does not match, the transport stays muted and the panel shows why.
- Failed changes retry immediately three times, then every five seconds.
- **Secondary clock supervision.** The service continuously compares each secondary interface's host/sample timestamps with the Sync Source. A deviation larger than `max(32, callbackFrames/4)` frames, sustained over at least three callbacks spanning 20 ms, mutes that interface and shows a warning. The mute is latched until the service restarts; StudioPatch deliberately does not unmute without evidence that the clock is locked again. This is timestamp supervision, not a direct read of the hardware lock status.

## Latency model

For each direction, the virtual device reports:

```text
reported latency = Sync Source device latency + largest Sync Source stream latency + StudioPatch margin
```

The StudioPatch margin is `max(ceil(sampleRate / 3000), engine I/O buffer)` frames in each direction. Safety offsets equal the Sync Source's and are reported separately. Latency changes are applied through a Core Audio configuration change, because a property notification alone does not update the HAL's scheduling.

Reporting is referenced to the Sync Source on purpose. Other interfaces can have different real path latencies; the panel's Advanced section shows their calculated difference. Measured figures and limits are in [LATENCY.md](LATENCY.md).

## Security model

- The broker accepts exactly two kinds of peers: Apple's Core Audio daemon and a StudioPatch service whose code signature satisfies the designated requirement captured at build time (`Dist/service.requirement`).
- The service must run in the **active console session**. Background users under fast user switching are not authorized. This is a current product limitation.
- The app and the embedded service are signed with the same certificate and identifier (`se.studiopatch.app`) so they share one microphone permission and one notification identity. Ad hoc signing is not supported.
- After changing the signing identity, reinstall the broker together with the app and driver; a correctly signed service is rejected by a broker that holds the old requirement.

## Fault handling and recovery

- Missing hardware, format errors and driver errors mute audio, show a status message, send at most one notification per failure, and retry automatically.
- HAL initialization publishes the device immediately with silent transport, then connects to the broker on a worker thread with bounded backoff. If the broker restarts, the driver re-registers its existing mapping.
- If the driver's plug-in lookup fails, the service falls back to enumerating plug-in bundle IDs.
- **Bounded self-restart.** If Core Audio reports a bad-object error at least three times over ten seconds, or a control call is blocked for 30 seconds, the service replaces its own process image. `recovery-attempt.json` limits this to once per ten minutes across restarts. A second failure in that window stops the service with a successful exit, so launchd does not loop, and the panel shows the reason. StudioPatch never restarts Core Audio, the broker or other processes.

## Preset device identity and labels

Presets store a stable `virtualDeviceUID` and the current `virtualDeviceName`. The UID is included in the engine payload; the display name is excluded so rename only publishes metadata. Configuration wire version 2 carries the UID, while version 1 remains readable for the legacy device. A UID change retires/mutes the old endpoint and removes/adds native driver objects. An unchanged UID keeps the existing endpoint during format changes. The shared transport memory layout is unchanged.

The service publishes routing-derived defaults through `spnm` and display names through `spdn`. The panel writes manual aliases using HAL’s `kAudioObjectPropertyElementName`; an empty CFString clears an alias. Writes verify the expected active UID and channel direction/count. No physical-interface name setter is exposed. The panel reads the effective virtual names from inventory. Wildcard-element listeners wake the service, and a file observer delivers its inventory snapshot to the panel without waiting for the polling timer. Timers remain fallback paths.

Manual aliases are not part of preset comparison or new preset serialization. Save-as-new obtains effective/default names before switching and copies only differing strings to the new UID. Pending transfers live in memory and errors report partial completion. Label ownership and the outstanding native HAL lifecycle checks are described in [the design](PRESET-IDENTITY-AND-LABELS.md) and [verification record](LABEL-VERIFICATION.md).

## Files on disk

| Location | Written by | Contents |
|---|---|---|
| `~/Library/Application Support/StudioPatch/last-session.json` | Panel | Current configuration: channel counts, routes (including inactive ones), interfaces, display order, active preset UID/display name. Manual labels are stored only in Core Audio. |
| `~/Library/Application Support/StudioPatch/presets.json` | Panel | Named presets. |
| `~/Library/Application Support/StudioPatch/runtime-status.json` | Service | Live status, device inventory and timing diagnostics. |
| `~/Library/Application Support/StudioPatch/recovery-attempt.json` | Service | Time of the last automatic self-restart. Do not delete it to force retries. |
| `~/Library/LaunchAgents/se.studiopatch.runtime.plist` | `install-service.sh` | Starts the service at login. Points to `Dist/` in your clone. |
| `/Library/Audio/Plug-Ins/HAL/StudioPatch.driver` | `install-driver.sh` | The Core Audio driver. |
| `/Library/PrivilegedHelperTools/se.studiopatch.transport/` and `/Library/LaunchDaemons/se.studiopatch.transport.plist` | `install-transport.sh` | The broker and the service signing requirement it enforces. |
| `/Library/Audio/StudioPatch Backups/` | `install-driver.sh --replace` | Previously installed drivers. |

## Source map

| Path | What it contains |
|---|---|
| `Sources/App.swift` | SwiftUI control panel and its `Model`: autosave, presets, labels, device order, interface selection. |
| `Sources/Matrix.swift` | AppKit routing matrix with frozen row/column headers and hover highlighting. |
| `Sources/Preset.swift` | The configuration model, validation, engine payload and retry schedule. Shared by app, service and tests. |
| `Sources/SessionStore.swift` | Atomic session file and preset library storage. |
| `Sources/RuntimeController.swift` | The service's state machine, independent of SwiftUI. |
| `Sources/RuntimeConnection.swift` | Status file, notifications, and starting the LaunchAgent. |
| `Sources/RuntimeTypes.swift` | Shared types, the serial Core Audio worker queue, device and directory observers. |
| `Sources/Service.swift`, `ServiceRecovery.swift` | Service entry point, singleton lock and bounded self-restart. |
| `Sources/Bridge.h`, `Bridge.mm` | C interface from Swift to Core Audio: inventory, configuration, rate changes, start/stop. |
| `Sources/DirectEngine.hpp` | Physical callbacks, routing and timing for the direct transport. |
| `Sources/Driver.cpp` | The AudioServerPlugIn: virtual device, streams, properties, timestamps. |
| `Sources/TransportBroker.cpp`, `SharedTransport.hpp` | The broker and the shared-memory layout it hands out. |
| `Sources/Core.hpp`, `Latency.hpp`, `ChannelNames.hpp`, `RateWire.hpp`, `RateSync.hpp` | Shared constants, property selectors and small wire formats. |
| `Sources/RouteSlot.hpp`, `AsyncResource.hpp`, `Timing.hpp`, `HostStorage.hpp` | Lock-free routing swap, asynchronous broker acquisition, optional timing telemetry, and deadlock-safe host storage. |
| `Sources/Inspect.cpp` | `patch-inspect`. |
| `Tests/` | Test suites; see [CONTRIBUTING.md](../CONTRIBUTING.md#tests). |
| `Tools/` | Latency measurement and analysis tools; see [LATENCY.md](LATENCY.md#measuring-latency). |
| `Vendor/libASPL/` | Pinned copy of [libASPL](https://github.com/gavv/libASPL) at `633e0f70203edd87d320fc5a3cae901e1363aac5`, with local changes: asynchronous host notifications, I/O cycle info for timing, and an opt-in separate lock for client start/stop. |

## Design decisions worth knowing

These were considered and deliberately rejected or deferred. The [architecture review record](history/REVIEW-ACTIONS-2026-10-23.md) has the reasoning.

- **No common alignment of all interfaces.** Aligning fast paths to the slowest interface would add latency to the Sync Source path.
- **No automatic unmute after a secondary clock fault.** It could hide unsynchronized audio.
- **Margin of one full engine buffer.** A 16-frame output margin produced short playback corruption under load at 48 kHz. A lower-latency mode would need separate qualification.
- **Adding or removing an interface restarts the transport.** Only routing-only edits are seamless. Preserving the Sync Source callback across graph changes is possible future work.
- **Tagged sample storage is kept** after profiling; a cheaper "high-water mark" scheme is unsafe after gaps and wraparound.
- **File-based control channel instead of XPC** between panel and service, because it removed polling without adding a second protocol.
