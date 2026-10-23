# Background engine and control panel

Status: implemented test version. StudioPatchService runs the engine in a separate process, with a process lock preventing duplicate instances. The control panel is the sole writer of the atomic session file; the service reads the desired configuration and writes a separate timestamped status file. The service can be registered with Scripts/install-service.sh to start at login and restart after crashes. No new driver or service has been installed automatically.

Current tradeoff: even routing-only changes trigger an automatically coordinated transport restart, potentially causing a brief audio interruption. Lock-free routing changes at a block boundary are not implemented. Channel counts change through HAL configuration on existing device objects; streams are recreated. Each change uses a new shared ring/timebase and keeps audio silent until both endpoints are ready. The virtual driver supports 8–384 kHz; master ranges are restricted to this range.

Verified: six test suites and separate-process integration with a simulated native backend. Integration covers automatic startup without the panel, singleton behavior, routing changes, silence on failure, recovery and rate requests. The core test covers format changes with an active control handler, preserved device ID, new stream widths, 192 kHz, published formats and silence during transitions. The pure C++ RuntimePolicy is a reference test; actual service orchestration resides in Swift Model.runtimeTick and is tested separately. Actual HAL/Ableton interaction, system notifications and login startup remain to be verified after installation.

## Intended behavior and remaining requirements

A separate per-user service owns hardware I/O and starts automatically with the saved configuration. The control panel sends versioned configuration requests and reads status through local IPC. Closing or quitting the panel must not stop audio. The service must be a singleton; reconnecting must not create duplicate aggregates. The settings file must have a single writer, without competing app and service processes.

Routing snapshots switch at an audio-block boundary. Channel counts/formats change through HAL's RequestDeviceConfigurationChange/PerformDeviceConfigurationChange. The visible device must retain its identity. The internal bridge and visible device must be coordinated; no callback may use the new channel count with old buffers. No control code, file I/O, IPC or allocation may run in the audio callback. Old snapshots are released only after the callback has finished using them.

The master's reported AvailableNominalSampleRates are read and published as StudioPatch's available rates. The service must handle every published rate, including changing ADAT/MADI channel counts. If another selected interface does not support a master rate, the requested transition must produce silence and status rather than a false success.

An Ableton request has a generation and a desired rate. The service silences transport, requests the master change, waits for the confirmed master rate, synchronizes other interfaces and inventories channel formats again. Audio resumes only when all participants and the virtual device confirm the same rate and format. A stale hardware value during transition must not overwrite the client request. Newer requests supersede older ones. Disconnection and failure leave the engine silent. The initial attempt is followed by three immediate retries, then five seconds between attempts.

Errors remain visible in the panel. System notifications are optional, require macOS permission and must be deduplicated per error transition, rather than sent on every retry. Denied notification permission must never block the audio engine.

## Verification before delivery

- Separate process: audio continues when the panel is closed or quit; reopening reconnects without interruption.
- Routing: one-to-many, never mixing; inactive channels retain connections but remain silent.
- Format: client connected during increases/decreases, both directions including zero channels in one direction; object identity and channel names are preserved correctly.
- Rate: 48/96/192 kHz in both directions where the master supports them; rejection, timeout, partial group synchronization, a new request during transition, disconnection and reconnection.
- Realtime: no stale ring data after failure/recovery, no snapshot-switch races, no notification deadlocks.
- Regression: the existing five test suites plus RuntimePolicyTests, followed by actual HAL/Ableton verification after explicit driver installation.
