# Project status

**Version 0.2.0. Experimental, hardware-tested development prototype.**

StudioPatch has been developed and tested on its author's studio setup, and its architecture has been through a full review (all 19 findings addressed or explicitly accepted). It has **not** been qualified as a general release: it has been tested on one Mac with one combination of interfaces, there are no signed or notarized builds, and several failure modes have only been tested in simulation.

## Preset identity and labels — 2026-10-24

The working tree implements per-preset virtual UIDs and Core Audio-owned channel labels, including a copy choice on Save current as new. The updated driver/app must be installed together. The signed package was installed and the Mac restarted on 2026-10-24. The updated driver and runtime are running.

Setting, clearing, copying and channel-name notifications passed live Core Audio probes on disposable private aggregates in both directions. Driver/model tests cover identity changes, retiring the old endpoint, no dirty marker for labels, stable identities on reopen and partial-copy failures. Service integration tests cover UID changes at unchanged audio format and display-name changes without an engine restart.

Native StudioPatch label retention across repeated preset disappearance/reappearance passed on 2026-10-24: two 46-input/40-output presets (legacy UID and a new per-preset UID) retained every input and output label when switched back and forth twice. Independent Core Audio inventory reads were compared, and the original active preset was restored. A known manual label on the legacy UID also survived the Mac restart. Audio MIDI Setup displayed the copied labels under the new device identity. Shrink/grow, reboot retention for newly created preset UIDs, and DAW identity refresh remain unverified. Label edits now save on focus loss, Return, Done or Escape; focus-loss and Done saves were verified against live Core Audio, and all eight test suites passed. Explicit destroy/recreate of a **private aggregate** did not retain labels; that experiment does not prove how HAL treats a native driver endpoint. See [verification details](LABEL-VERIFICATION.md).

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
