# Latency and safety-offset audit — 2026-11-15

The owner requested investigation of the earlier 64-frame / 0.667 ms added round trip at 96 kHz and 32-frame engine I/O, conditional larger margins, and a suspected safety-offset reporting defect. Local changes and reasonable service/buffer restarts were authorized; no push or third-party transmission was authorized. Safari and Ableton Live were left playing through StudioPatch.

## Result of reducing the margin

The current 64 + 64 frame policy remains. Reducing only the 32-frame engine case to 32 + 32 frames failed deterministic schedules that stay within the existing producer completion budgets. This is a counterexample to safely selecting the lower policy solely from engine/client block sizes; it is not a claim that lower margins always fail, or that a future coordinated scheduler cannot support them.

Experiments copied the real `TransportTimingTests.mm`, driver handler and engine callback into ignored `work/` directories. They delayed publication while retaining the contiguous sample ranges belonging to the scheduled cycle. No synthetic signal was sent to hardware.

| Policy at 96 kHz | Cases | Cases with missing/corrupt samples |
|---|---:|---:|
| Existing two blocks | 57 | 0 |
| One block only for 32-frame hardware | 57 | 36 |

Immediate-publication cases passed under both policies. Specific lower-margin counterexamples included:

- Hardware 32, client 32, relative phase 7, client completion after 31 frames: 15,897 missing playback samples in the checked interval.
- Hardware 32, client 128, phase 7, client completion after 127 frames: 3,993 missing playback samples.
- A 32-frame hardware producer publishing 31 frames after its scheduled cycle lost capture samples, including with larger clients. Giving a larger secondary its own two-block margin did not protect the late short master.

Those delays are within the respective callback periods. The counts are simulation sample checks across the fixture's two routes, not audible live incidents. Added regression cases cover delayed master capture, delayed client playback, unequal secondary blocks, and deadline ordering at 48/96/192 kHz.

For hardware period H, playback client period C and publication delay L, an independent-phase model needs up to `max(0, 2H - C + L)` playback padding. Allowing L to approach C recovers the two-H bound. Capture's requested tail does not gain slack from a larger client block: hardware phase plus publication delay D requires up to H + D. Reserving one H leaves no worst-case publication budget. These bounds describe the tested schedule model, not a guarantee against arbitrary operating-system stalls.

Normal service state has no per-client block metadata. Optional mixed-publication telemetry describes HAL's mixed writes, not each application's scheduling contract. Observed spare margin cannot guarantee a newly joining or subsequently late client's completion. Increasing padding after a miss also cannot repair that miss and changes the read position. No adaptive recovery, silent retiming, or unqualified low-margin mode was added.

## Confirmed safety-offset defect

Before the fix, `start()` cached the Sync Source safety offsets before `openDevice()` wrote its buffer setting. `openDevice()` then read the new values and applied a positive difference as extra delay even to the Sync Source itself. Global latency reporting included the normal transport padding and reported the new hardware safety separately, but omitted that extra tag/read shift.

A mocked HAL changes the accepted safety from 48/48 to 128/96 when accepting a 128-frame buffer. The real callback then added 80 capture frames and 48 playback frames beyond the reported transport margin. The regression failed on actual ramp sample positions before the fix, and passes afterward.

The fix reads safety after all members' buffer writes, establishes the accepted master reference, and computes secondary differences in a separate pass. The master always has zero extra safety difference. Tests cover either preset order, both directions, the published latency values, and a failed post-write input query: the known pre-write value is retained, the readable output value is accepted, and a warning reports incomplete timing information. No audio-thread work, shared-memory layout change, driver reinstall, or automatic restart policy is introduced.

This fixes initialization/configuration. Later property changes or query recovery do not dynamically recompute running secondary alignment offsets; those remain refreshed at an engine rebuild. The UFX III kept its 48/48 safety offsets in the live buffer tests, so the changing-offset defect was established with the deterministic HAL fixture, not reproduced on this hardware.

## Evidence

- `work/latency-policy-experiments-20261115/`: copied fixtures, current/short-policy results, within-budget playback counterexamples and negative regression output.
- `work/latency-audit-20261115/`: settings/client snapshots and independent one-block capture counterexample.
- `build/safety-init-regression/safety-init-before.log` and `safety-init-after.log`: failing/passing safety regression.
- `build/latency-audit-20261115/`: isolated build, signed service staging and activation evidence.
- `work/buffer-investigation-2026-11-14/latency-*-summary.json` and corresponding timing JSONL files: baseline and fixed-service live windows (the earlier collector was reused).

Live validation and final deployment are recorded in `Docs/STATUS.md`.
