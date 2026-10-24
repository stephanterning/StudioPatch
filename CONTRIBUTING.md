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
| `core-tests` | `Tests/CoreTests.cpp` | The driver: device and stream properties, channel counts and formats, configuration changes with an active client, channel names, timestamps, custom property registration, deadlock-safe host storage. |
| `route-tests` | `Tests/RouteTests.mm` | Routing in the audio callback with synthetic buffers: reordering, both directions, silence for unused and removed routes. |
| `direct-tests` | `Tests/DirectTests.mm` | The shared-memory transport: cross-process visibility, independent capture/playback, fan-out, silence for overwritten frames, clock freshness, secondary clock supervision, malformed buffers. |
| `rate-tests` | `Tests/RateTests.cpp` | Sample-rate synchronization policy with simulated driver calls. |
| `preset-tests` | `Tests/PresetTests.swift` | The configuration model: inactive routes, validation, older file formats, engine payload. |
| `session-tests` | `Tests/SessionTests.swift` | The real app `Model` with an isolated session file: autosave, restore, labels, unplugged interfaces, removal confirmation, the asynchronous Core Audio worker. |
| `capture-stream-tests` | `Tests/CaptureStreamTests.cpp` | The streaming writer used by the latency capture tool. |
| `async-resource-tests` | `Tests/AsyncResourceTests.cpp` | Asynchronous broker acquisition, retry and cancellation. |
| `Scripts/test-runtime.sh` | `Tests/ServiceRecoveryTests.swift`, `Tests/RuntimeIntegration.py`, `Tests/RuntimeFake.cpp` | The real service running as a separate process against a fake audio backend: autonomous start, singleton lock, routing edits, notifications, sample-rate requests, unplug/reconnect, self-restart and its rate limit. The script refuses to run if the fake build links any real Core Audio entry points. |

Focus tests on behavior that can break audio or lose user data, not on implementation details. Hardware behavior that cannot be tested automatically should be described in the pull request, with how you verified it.

## Rules that keep audio safe

These invariants are easy to break by accident. Please keep them in mind when reviewing or changing code.

- **Audio callbacks must never block.** No allocation, locks shared with control code, XPC, file I/O or logging on the audio thread.
- **Missing audio is silence.** Stale, overwritten or not-yet-written frames must read as zeros, never as old samples.
- **Report latency honestly.** Do not lower reported values to make numbers look better.
- **The panel is the only writer of `last-session.json`.** The service only reads it.
- **Driver, broker and service must match.** They share the memory layout in `Sources/SharedTransport.hpp`. If you change it, change `SharedTransport::Magic` so mismatched components refuse to connect, and note in the pull request that all three must be reinstalled together.
- **Old configurations must still load.** Keep obsolete fields in `Preset` decodable.
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
