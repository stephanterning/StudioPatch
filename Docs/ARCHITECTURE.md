# Architecture

This document describes how StudioPatch 0.2 works. It is written for developers who want to understand or change the code. For day-to-day use, see the [user guide](USER-GUIDE.md).

## Components

StudioPatch consists of four programs that work together:

| Component | Language | Runs as | Responsibility |
|---|---|---|---|
| `StudioPatch.app` | Swift / SwiftUI | The logged-in user, only while open | Control panel. Edits the configuration, saves it, and shows status. Closing it does not stop audio. |
| `StudioPatchService` | Swift + Objective-C++ | Per-user LaunchAgent `se.studiopatch.runtime` | The audio engine. Owns all physical audio I/O, applies routing and format changes, handles sample-rate requests, and sends notifications about problems. Embedded in the app bundle. |
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
2. The service watches the session directory and Core Audio device notifications. A one-second heartbeat handles status, client sample-rate requests and retries; device inventory has a five-second fallback refresh. A pending configuration gets 25 ms follow-ups only during the first second of that request. A newly started engine gets the same one-second burst to publish promptly when its clock arrives. The deadlines use monotonic uptime and are not renewed by retries. After the burst, the ordinary heartbeat continues waiting; no request is cancelled, no audio is stopped, and nothing restarts because the burst ends. Confirmation errors still use the existing retry schedule.
3. The service compares the desired configuration with what is running:
   - **Routing-only change:** new immutable routing tables are swapped in at a block boundary. Audio keeps running and the DAW sees no format change.
   - **Anything else** (channel counts, sample rate, interface set, Sync Source, engine buffer), or hardware that no longer matches the running graph: when the rate changes, the Sync Source rate changed, or audio starts, the Sync Source is asked for the target rate while routing continues, and locked interfaces follow its confirmed rate. Other changes leave hardware rates alone. The service requests a fresh virtual-device generation through Core Audio's `RequestDeviceConfigurationChange`. Only after HAL has applied that generation does it replace the hardware engine. Expect an audio interruption when the change is actually applied.
4. The service writes a timestamped `runtime-status.json`. It includes a structured health level (`idle`, `healthy`, `warning`, `error`) for presentation; this value never controls audio. The panel treats a snapshot older than 12 seconds as "service not responding".

When the panel opens, it starts the registered LaunchAgent (`launchctl kickstart`, bootstrapping it if needed). It never spawns an unmanaged copy of the service when a LaunchAgent is registered. A process lock (`runtime.lock`) guarantees a single engine.

### Driver properties

The service talks to the driver through custom Core Audio properties on the persistent plug-in object, which remains accessible while the virtual device is absent. The important ones:

| Selector | Purpose |
|---|---|
| `spcf` | Virtual device configuration (channel counts, rate, buffer). |
| `spnm` | Routing-derived default channel names. HAL manual aliases take precedence. Applied without reconfiguring audio. |
| `spdn` | Preset device display name, independent of its stable UID. |
| `sprt` / `sprq` | Rates the Sync Source supports / a sample-rate change requested by a DAW. |
| `splt` | Input/output latency and safety offsets; writes are bound to a transport generation. Reads return the four applied values, including while the endpoint is unpublished. |
| `spav` | Public device availability (`0`/`1`). Authenticated removal/publication with HAL device-list notifications. |
| `spts` | Transport status (`connecting`/`ready`) and connection attempts. |
| `spdr` | Shared-memory transport registration. |

Writes to these properties require the broker-registered process ID of the currently authenticated service. Standard HAL sample-rate requests from DAWs remain open to all clients.

## Sample rates and clocking

- The Sync Source's available sample rates (limited to 8–384 kHz) become the rates the virtual device offers.
- A rate change can come from the panel or from a DAW changing the StudioPatch device's rate. DAW requests take priority over an older panel request.
- Each secondary interface has a **sync lock**. Locked interfaces follow the rate the Sync Source actually reaches when the Sync Source or StudioPatch changes rate. One that cannot follow is reported and left at its own rate. A locked interface changed elsewhere is reported as not in sync and is not set back while audio runs. Unlocked interfaces are never changed; a rate mismatch does not prevent routing.
- A client rate request on the StudioPatch device (or a stream format at another rate) is only forwarded to the service; the device keeps reporting its running rate until a new configuration replaces it. If the Sync Source refuses or its rate cannot be confirmed, StudioPatch stays at the running rate, acknowledges the request and reports the refusal, so the DAW sees the correct rate.
- If the Sync Source refuses a requested rate, the engine runs at the rate it reports, the request is acknowledged and the refusal is shown in status. A request that was already applied or refused is only acknowledged again if the acknowledgement failed; it is never applied twice. If the rate query fails, the current rate stays in effect. A client rate request does not silence the running session; the next rebuild applies it.
- Failed changes retry immediately three times, then every five seconds.
- **Clock diagnostics, without automatic muting.** Secondary timestamp deviation and its peak are observations only. Neither a threshold, duration, nor a cross-device timestamp-age comparison gates their samples. Master host/sample prediction differences no longer invalidate the engine. If the master's sample counter moves backwards, its local timestamp translation advances the shared timeline monotonically and updates the clock epoch; I/O continues and secondary mappings follow that epoch. No user clock settings are changed. Unlocked members are not required to report the master's nominal rate. The HAL driver also copies matching tagged frames regardless of clock snapshot age; missing frame tags still return silence. The shared-memory layout is unchanged.


## Latency model

For each direction, the virtual device reports:

```text
reported latency = Sync Source device latency + largest Sync Source stream latency + StudioPatch margin
```

The StudioPatch margin is `max(ceil(sampleRate / 3000), startup margin, largest observed Sync Source callback block)` frames in each direction. Padding is atomic shared state. It can grow during an engine lifetime, but short or variable blocks cannot reduce it and move read positions forward. A new engine starts a new margin. A growth transition can change latency and is not claimed to be glitch-free. Driver, broker and service must use the matching shared-memory protocol (`Magic` ending in `4359`). Safety offsets equal the Sync Source's and are reported separately. Latency changes are applied through a Core Audio configuration change, because a property notification alone does not update the HAL's scheduling.

Reporting is referenced to the Sync Source on purpose. Other interfaces can have different real path latencies; the panel's Advanced section shows their calculated difference. Measured figures and limits are in [LATENCY.md](LATENCY.md).

## Security model

- The broker accepts exactly two kinds of peers: Apple's Core Audio daemon and a StudioPatch service whose code signature satisfies the designated requirement captured at build time (`Dist/service.requirement`).
- The service must run in the **active console session**. Background users under fast user switching are not authorized. This is a current product limitation.
- The app and the embedded service are signed with the same certificate and identifier (`se.studiopatch.app`) so they share one microphone permission and one notification identity. Ad hoc signing is not supported.
- After changing the signing identity, reinstall the broker together with the app and driver; a correctly signed service is rejected by a broker that holds the old requirement.

## Fault handling and recovery

Only two things stop running audio: confirmed physical disconnection of a preset interface, and an applied configuration change that needs a rebuild. Everything else is shown in the status line and retried while audio keeps running.

- All physical members of the active preset are required, including unrouted members. An interface missing from the inventory is treated as disconnected only after Core Audio's UID lookup or alive flag confirms it (`SPMissingDevices`); an inventory metadata read failure is not a disconnection. Confirmed loss stops routing, retires the public endpoint, marks it not alive and removes it from the HAL device list. An empty selection also withdraws the device.
- Session, label, inventory, rate-query, status, broker-authorization, driver-lookup and publication failures never stop running audio or withdraw the endpoint. The last readable configuration stays in effect.
- The direct engine has no property listeners and no global invalidation flag. A malformed buffer skips only that callback. A secondary whose own sample counter restarts is realigned to the shared timeline. Each heartbeat compares every interface's stream layout with what the graph was built against; a difference requires a rebuild. The Sync Source callback supplies the actual block length and updates the transport padding before copying samples, including when the initial buffer-property read failed. Block-length changes do not require a rebuild. Latency and safety offsets are republished to Core Audio when they change, without a rebuild; secondary alignment offsets are refreshed at the next rebuild. Toggling sync lock is a routing-level update.
- A rebuild starts with what the hardware accepts. Routes to unavailable channels, missing interfaces or already-used outputs stay silent and are listed in status. A secondary that fails to open or start is reported and left out until the next rebuild; only a Sync Source failure fails the start. Unreadable alive/transport flags, buffer size, stream format, safety offsets or latency do not fail the start; unreadable timing is reported. Waiting for HAL to apply the reported timing is bounded to two seconds while the transport is still silent and never fails the start.
- `SPConfigure` submits the real configuration while the old engine is still running; a control-access check before an intentional hardware rate write never authorizes stopping that engine. It remembers an outstanding request, its original generation and configuration. Later calls only confirm that request, even after a failed property read or broker claim. A new generation plus matching configuration confirms application; readiness with the old generation confirms rejection. Merely reading the same format is not enough, since restarts also require fresh storage.
- An accepted request is resolved before processing a newer preset edit, including an edit back to the currently running configuration. Confirmed physical removal still withdraws the public endpoint while a request is pending. A late HAL completion cannot republish it.
- `SPSetHardwareRate` reports a rate only after reading it back. If readback fails after a successful write, the old engine stays running and the unknown rate is not guessed. A later confirmed rate drives the configuration change. Locked members are never steered from an unconfirmed rate. If a refused request leaves the existing graph and rate unchanged, it is acknowledged without stopping the engine.
- `SPPrepareChange` checks request syntax and broker/plug-in access before a running engine is asked to change hardware rate. This avoids a known control failure causing a needless hardware write; it cannot close the race to the actual command. `SPSetHardwareRate` also says whether it wrote the Sync Source in that call; that is the only rate write a rejected change may undo. The service remembers that write until the change is applied, rejected or no longer needed, so a later attempt after an unreadable readback can still undo it.
- HAL rejection keeps the old engine and is reported once; the same rejected change is not resubmitted every heartbeat. If StudioPatch wrote the Sync Source in that attempt, it sets the Sync Source and locked interfaces back to the running engine's rate once and reports the result; a rate changed by something else is never set back. Control failures retry the existing operation using the normal retry schedule. After HAL has committed a new generation, a hardware-engine start can still fail: audio is then off, the endpoint stays published, the problem is notified once and the change is retried while audio is off. There is no automatic return to the previous configuration. An unreadable rate never authorizes a change. Status, labels and the sync check use the running configuration.
- In the driver, a client rate request and a pending or rejected configuration change leave the current session usable; only retirement (withdrawal or a preset identity switch) silences it.
- If the driver's plug-in lookup fails, the service falls back to enumerating plug-in bundle IDs.
- **No self-restart.** The service never replaces or terminates itself. launchd restarts it after a crash (`KeepAlive` on unsuccessful exit, five-second throttle). The user can restart it from the panel (a button while audio is off, and the StudioPatch menu), which runs `launchctl kickstart -k`. StudioPatch never restarts Core Audio, the broker or other processes.

## Preset device identity and labels

Presets store a stable `virtualDeviceUID` and the current `virtualDeviceName`. The UID is included in the engine payload; the display name is excluded so rename only publishes metadata. Configuration wire version 2 carries the UID, while version 1 remains readable for the legacy device. A UID change retires the old endpoint at the driver configuration commit and leaves the replacement unpublished. The service starts the new engine and publishes the replacement only after its hardware clock is available. A switch is not a problem, so it does not notify. A control failure before commit preserves the old endpoint. An unchanged UID keeps the existing endpoint during format changes. Preset identity changes do not alter the shared-memory schema. All components must nevertheless match the current transport protocol version.

Fan-out channel names use the effective preset's interface order, not HAL inventory order. The service keeps the running graph's display name separately from its engine payload (which intentionally excludes names), so a pending change for another UID cannot relabel the running device. Renaming the active UID remains a metadata-only update. The service publishes routing-derived defaults through `spnm` and display names through `spdn`. The panel writes manual aliases using HAL’s `kAudioObjectPropertyElementName`; an empty CFString clears an alias. Writes verify the expected active UID and channel direction/count. No physical-interface name setter is exposed. The panel reads the effective virtual names from inventory. Wildcard-element listeners wake the service, and a file observer delivers its inventory snapshot to the panel without waiting for the polling timer. Timers remain fallback paths.

Manual aliases are not part of preset comparison or new preset serialization. Save-as-new obtains effective/default names before switching and copies only differing strings to the new UID. Pending transfers live in memory and errors report partial completion. Label ownership and the outstanding native HAL lifecycle checks are described in [the design](PRESET-IDENTITY-AND-LABELS.md) and [verification record](LABEL-VERIFICATION.md).

Physical input and output labels are a separate, panel-owned registry in `source-labels.json`, keyed by stable physical UID, direction and channel number. They are shared across presets and never enter the engine payload or routing-derived defaults. Existing input entries remain valid. An absent override resolves to the current interface/channel name. The panel compares this effective label with the actual connected virtual channel name. Both mismatching labels are orange, and clicking either copies its displayed value to the other side. A physical-label click writes the virtual HAL alias; a Core Audio-label click writes the selected physical alias in the local registry. In To Computer the physical side is Source; in From Computer it is Destination. Input rows target To Computer; physical output rows target their connected From Computer channel. From Computer Source cells display the actual virtual Core Audio label. Outputs sharing a virtual source compare independently, and all show pending status while that source's name is being written. The panel checks the captured preset/routing before writing and after readback, and shows a match only from read-back names. Interface-label saves are atomic and reload the registry first; unreadable storage is reported and preserved. Hardware channel names remain read-only.

## Files on disk

| Location | Written by | Contents |
|---|---|---|
| `~/Library/Application Support/StudioPatch/last-session.json` | Panel | Current configuration: channel counts, routes (including inactive ones), interfaces, display order, active preset UID/display name. Manual labels are stored only in Core Audio. |
| `~/Library/Application Support/StudioPatch/presets.json` | Panel | Named presets. |
| `~/Library/Application Support/StudioPatch/source-labels.json` | Panel | Physical input and output aliases shared across presets; separate from virtual Core Audio labels. |
| `~/Library/Application Support/StudioPatch/runtime-status.json` | Service | Live status, device inventory and timing diagnostics. |
| `~/Library/LaunchAgents/se.studiopatch.runtime.plist` | `install-service.sh` | Starts the service at login. Points to `Dist/` in your clone. |
| `/Library/Audio/Plug-Ins/HAL/StudioPatch.driver` | `install-driver.sh` | The Core Audio driver. |
| `/Library/PrivilegedHelperTools/se.studiopatch.transport/` and `/Library/LaunchDaemons/se.studiopatch.transport.plist` | `install-transport.sh` | The broker and the service signing requirement it enforces. |
| `/Library/Audio/StudioPatch Backups/` | `install-driver.sh --replace` | Previously installed drivers. |

## Source map

| Path | What it contains |
|---|---|
| `Sources/App.swift` | SwiftUI control panel and its `Model`: autosave, presets, labels, device order, interface selection. |
| `Sources/Matrix.swift`, `Sources/MatrixGroups.swift` | AppKit matrix, inferred channel banks and collapsed-axis projection. Routing and label actions retain original channel indices; grouped cells only expand. Aggregate counts are derived from existing routes. Fold preferences use UserDefaults independently of audio configuration, keyed by interface UID/direction or virtual preset UID. |
| `Sources/Preset.swift` | The configuration model, validation, engine payload and retry schedule. Shared by app, service and tests. |
| `Sources/SessionStore.swift` | Atomic session file, preset library and physical interface label storage. |
| `Sources/RuntimeController.swift` | The service's state machine, independent of SwiftUI. |
| `Sources/RuntimeConnection.swift` | Status file, notifications, and starting the LaunchAgent. |
| `Sources/RuntimeTypes.swift` | Shared types, the serial Core Audio worker queue, device and directory observers. |
| `Sources/Service.swift` | Service entry point and singleton lock. |
| `Sources/Bridge.h`, `Bridge.mm` | C interface from Swift to Core Audio: inventory, configuration, rate changes, start/stop. |
| `Sources/DirectEngine.hpp` | Physical callbacks, routing and timing for the direct transport. |
| `Sources/Driver.cpp` | The AudioServerPlugIn: virtual device, streams, properties, timestamps. |
| `Sources/TransportBroker.cpp`, `SharedTransport.hpp` | The broker and the shared-memory layout it hands out. |
| `Sources/Core.hpp`, `Latency.hpp`, `ChannelNames.hpp`, `RateWire.hpp`, `RateSync.hpp` | Shared constants, property selectors and small wire formats. |
| `Sources/RouteSlot.hpp`, `AsyncResource.hpp`, `Timing.hpp`, `HostStorage.hpp` | Lock-free routing swap, asynchronous broker acquisition, optional timing telemetry, and deadlock-safe host storage. |
| `Sources/Inspect.cpp` | `patch-inspect`. |
| `Sources/AbletonToolsView.swift`, `Sources/AbletonLabels.swift`, `Tools/update-ableton-labels.swift` | Tools sheet and bundled `StudioPatchAbletonLabels` helper. Reads current Core Audio names, checks Live is closed, conservatively patches recognized preferences, backs up and atomically replaces the file. Native counterpart of the optional Python CLI; no Python or compiler is required at runtime. |
| `Tests/` | Test suites; see [CONTRIBUTING.md](../CONTRIBUTING.md#tests). |
| `Tools/` | Latency measurement and analysis tools; see [LATENCY.md](LATENCY.md#measuring-latency). |
| `Vendor/libASPL/` | Pinned copy of [libASPL](https://github.com/gavv/libASPL) at `633e0f70203edd87d320fc5a3cae901e1363aac5`, with local changes: asynchronous host notifications, I/O cycle info for timing, and an opt-in separate lock for client start/stop. |

## Design decisions worth knowing

These were considered and deliberately rejected or deferred. The [architecture review record](history/REVIEW-ACTIONS-2026-10-23.md) has the reasoning.

- **No common alignment of all interfaces.** Aligning fast paths to the slowest interface would add latency to the Sync Source path.
- **No watchdog or self-restart.** Hardware callbacks run independently of control work, so a slow control call is not a reason to replace the process, and a process restart cannot repair `coreaudiod`. launchd restarts the service only after a crash.
- **No automatic mute for inferred clock faults.** Clock setup belongs to the user. Timestamp diagnostics must not become a gate, a latched fault, or a reason to restart routing. Bounds/layout validation and absent-frame handling remain necessary to copy audio correctly.
- **Margin of one full engine buffer.** A 16-frame output margin produced short playback corruption under load at 48 kHz. A lower-latency mode would need separate qualification.
- **Adding or removing an interface restarts the transport.** Only routing-only edits are seamless. Preserving the Sync Source callback across graph changes is possible future work.
- **Tagged sample storage is kept** after profiling; a cheaper "high-water mark" scheme is unsafe after gaps and wraparound.
- **File-based control channel instead of XPC** between panel and service, because it removed polling without adding a second protocol.

### Status presentation and drift compensation

`SPStatus` reports the UIDs of secondary aggregate paths for which `AudioDeviceStart` succeeded. The controller uses those UIDs, rather than the requested preset checkbox, to omit compensated sample-rate mismatches from both status and notifications. Rate-control warnings carry an optional secondary UID so that a refused secondary rate follow does not remain a warning once that secondary is running through resampling. Master-rate failures, metadata errors and engine startup warnings remain visible. This records successful startup, not a new liveness/quality monitor. Driver/broker shared memory and audio decisions are unchanged; update the panel and service together for the new status JSON.

On healthy status, the service clears its known problem notifications (delivered and pending), including those left by a previous service process, and resets notification deduplication. It does not clear on warning, error, idle or unknown status. Each occurrence has a unique delivery ID so an authorization or delivery completion arriving after resolution can remove its own stale notification without removing a later occurrence. Notification bookkeeping stays on the main actor and does not control audio.
