# Contributing to StudioPatch

Thanks for your interest. StudioPatch is a small, experimental project, so questions, bug reports, test results from other audio interfaces and pull requests are all welcome. For larger changes, please open an issue first so we can agree on the approach.

## Getting oriented

1. Read the [README](README.md) for what StudioPatch does.
2. Read [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) for how the four components fit together and where things live in the source.
3. Check [Docs/STATUS.md](Docs/STATUS.md) for what is verified, what is not, and known limitations.

The code base is small: about 4,000 lines of Swift, C++ and Objective-C++ in `Sources/`, plus tests and tools.

## Build and test without installing anything

You do **not** need a signing certificate or administrator rights to compile the code and run the tests:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
bash Scripts/test-runtime.sh
```

Run a single suite with `ctest --test-dir build -R direct-tests --output-on-failure`.

To build the signed app bundle, driver and broker into `Dist/`, you need an Apple signing certificate (see [Docs/INSTALLATION.md](Docs/INSTALLATION.md)):

```sh
export STUDIOPATCH_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID1234)"
bash Scripts/build.sh
```

The scripts use `build/` for intermediate files; set `STUDIOPATCH_BUILD_DIR` to use another directory. `build/`, `Dist/` and `work/` are ignored by Git. Set `STUDIOPATCH_DIST_DIR` to stage a signed package separately without replacing a running service’s `Dist/` bundle.

You can open `Dist/StudioPatch.app` without installing the driver. Interfaces are listed and routing can be edited; audio stays off.

SwiftUI macro expansion and Keychain access do not work inside some sandboxes (including some AI coding tools). If the Swift build fails with macro or signing errors, run it from a normal Terminal.

## Tests

| Suite | Source | Covers |
|---|---|---|
| `core-tests` | `Tests/CoreTests.cpp` | The driver: device and stream properties, channel counts and formats, configuration changes with an active client, sample delivery while a change is pending, withdrawal during a pending change, preset replacement absent until explicit publication, channel names, timestamps, custom property registration, deadlock-safe host storage. |
| `direct-tests` | `Tests/DirectTests.mm` | The shared-memory transport: cross-process visibility, independent capture/playback, fan-out, silence for overwritten frames, clock diagnostics without muting, counter reset without stopping I/O, a malformed block affecting only itself, silent unavailable routes. |
| `bridge-fault-tests` | `Tests/BridgeFaultTests.mm` | The real bridge and engine code with simulated HAL reads: secondary lookup failures, an unreadable Sync Source rate, unreadable latency, latency-only changes, actual sample delivery with unknown/changing block lengths and nonshrinking variable-block padding, configuration-write/read/claim failures with one outstanding request, and contained timing confirmation. No Core Audio objects are touched. |
| `preset-tests` | `Tests/PresetTests.swift` | The configuration model: inactive routes, validation, older file formats, engine payload. |
| `session-tests` | `Tests/SessionTests.swift` | The real app `Model` with an isolated session file: autosave, restore, labels, unplugged interfaces, removal confirmation, the asynchronous Core Audio worker. |
| `matrix-group-tests` | `Tests/MatrixGroupTests.swift` | Inferred banks, nested 16-channel groups, stable IDs, both-axis expansion without routing edits, projected route/label hit mapping, fan-out counts, unavailable routes and isolated fold-preference persistence. |
| `capture-stream-tests` | `Tests/CaptureStreamTests.cpp` | The streaming writer used by the latency capture tool. |
| `async-resource-tests` | `Tests/AsyncResourceTests.cpp` | Asynchronous broker acquisition, retry and cancellation. |
| `ableton-native-tests` | `Tests/AbletonNativeTests.py`, `Tests/AbletonNativeHarness.swift` | Native preferences adapter parity with the Python adapter, backups, preservation of unrelated settings, invalid layouts, missing files/devices, Live-start and concurrent-save guards. Requires Python 3 for tests only. |
| `ableton-script-tests` | `Tests/AbletonNamesTests.py` | Optional Python CLI preferences adapter, naming rules, activation and restoration behavior. Requires Python 3. |
| `Scripts/test-runtime.sh` | `Tests/RuntimeIntegration.py`, `Tests/RuntimeFake.cpp` | The real service running as a separate process against a fake audio backend: autonomous start, singleton lock, routing edits, error-only notifications, sample-rate requests including refused and unconfirmed rates, unplug/reconnect, and audio continuing through settings, label, rate-query, driver-lookup, inventory-metadata, publication and control-connection failures, rejected changes with a one-time undo of StudioPatch's own Sync Source write, a failed start after commit (audio off, retried, no rollback), locked interfaces reported when out of sync, pending HAL changes followed by newer edits or disconnection, clock-ready preset publication, bounded fast follow-ups and preset-order fan-out names. The script refuses to run if the fake build links any real Core Audio entry points. |

Focus tests on behavior that can break audio or lose user data, not on implementation details. Hardware behavior that cannot be tested automatically should be described in the pull request, with how you verified it.

## Rules that keep audio safe

These invariants are easy to break by accident. Please keep them in mind when reviewing or changing code.

- **Audio callbacks must never block.** No allocation, locks shared with control code, XPC, file I/O or logging on the audio thread.
- **Keep connected interfaces routing. This is a fundamental product requirement.** Only two things may stop running audio: confirmed physical disconnection of a preset interface (then withdraw the endpoint from Core Audio), and an applied configuration change that needs a rebuild. Everything else is reported while audio keeps running: settings, label, inventory, status, broker, rate-query and publication failures, property notifications, timestamp deviations and rate mismatches. StudioPatch is for technically experienced audio users. It must not judge sound quality or clock correctness; accepting or fixing distorted or unsynchronized sound is the user's decision. Do not add watchdogs, recovery supervisors, thresholds or self-restarts without an explicit user requirement. Helpful automation such as sync lock stays, but it may only try: a refusal is reported and never prevents audio that would otherwise work. A rebuild runs with what the hardware accepts and reports the rest.
- **Failed changes are reported, not rolled back.** If a change fails after Core Audio has applied it, audio is off with a clear message and the change is retried while audio is off; there is no automatic return to the previous configuration. A change Core Audio rejects before applying it leaves the old engine running and is not resubmitted in a loop; StudioPatch then undoes only its own Sync Source rate write from that attempt, once. Waiting for an already submitted Core Audio request, acknowledgements, metadata and publication may keep trying while audio runs. Missing information (a failed query) keeps the current state; it is never a reason to change it.
- **System notifications report problems only.** Successful changes are shown in the panel's status line, not as notifications. Each problem notifies once while it lasts.
- **Limit an unusable part to itself.** An unaddressable buffer skips only its own callback, a route to a missing channel stays silent, and a secondary interface that cannot start leaves the others running. Missing requested frames contain no audio to copy; do not invent or replay samples.
- **Missing audio is silence.** Stale, overwritten or not-yet-written frames must read as zeros, never as old samples.
- **Report latency honestly.** Do not lower reported values to make numbers look better.
- **The panel is the only writer of `last-session.json`.** The service only reads it.
- **Driver, broker and service must match.** They share the memory layout in `Sources/SharedTransport.hpp`. If you change it, change `SharedTransport::Magic` so mismatched components refuse to connect, and note in the pull request that all three must be reinstalled together.
- **Backward compatibility is not required.** Remove obsolete migration paths and fields when they are no longer needed.
- **Never fall back to ad hoc signing.** Permissions and broker authentication depend on a stable certificate.
- **Never change the user's default devices or their own aggregate devices.**

## Testing on real hardware

- Use an isolated loopback (an output that does not reach speakers or headphones) and keep test signals at a low level. The tools in `Tools/` are described in [Docs/LATENCY.md](Docs/LATENCY.md).
- Back up `~/Library/Application Support/StudioPatch/` before experiments and restore it afterwards.
- Do not restart `coreaudiod` or kill the broker repeatedly on a machine you depend on. Repeated Core Audio restarts during development once left the whole audio system unusable until reboot. Use a separate test machine for that kind of fault testing.
- Report results as measured, including failed runs. "Not tested" is a useful result.

## Code style

- Match the surrounding code. The code base is compact and favors small, direct functions over abstraction layers.
- Comments explain non-obvious constraints and invariants ("why"), not what the next line does.
- Swift code shared between the app and service must not depend on SwiftUI; see which files each target compiles in `Scripts/build.sh`.
- `Vendor/libASPL` is a pinned copy with local changes. Keep changes there minimal and describe them in the pull request.

## Documentation

Update the documentation when behavior, installation steps or verified results change:

- User-visible behavior → [Docs/USER-GUIDE.md](Docs/USER-GUIDE.md)
- Design or component changes → [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)
- New measurements or limitations → [Docs/LATENCY.md](Docs/LATENCY.md), [Docs/STATUS.md](Docs/STATUS.md)

`Docs/history/` is a frozen archive; add new dated records there only for significant investigations.

## License

StudioPatch is licensed under [AGPL-3.0-only](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.
