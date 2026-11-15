# Coordinated delivery investigation — 2026-11-15

## Decision

An added 32 + 32 frames (0.667 ms at 96 kHz) is feasible in a scheduler that owns the necessary ordering. The isolated event model demonstrates this with multiple clients. It is not qualified for StudioPatch's generic virtual-device-to-physical-HAL architecture: the reviewed public interfaces do not establish the required ordering across arbitrary applications, device callbacks and client lifecycle changes. Production code, latency margins and running audio were left unchanged.

This is a narrower conclusion than saying that low latency is impossible. It distinguishes a working scheduling design from the ability to implement that design through the available APIs. The existing 64 + 64 frame policy also has a finite scheduling budget; it does not protect against arbitrary operating-system stalls. The proposed reduction loses cases within that existing budget unless stronger phase and completion conditions are enforced.

## Executable scheduling model

`work/coordination-audit-20261115/model.py` separates consumer start, producer completion, final mixing and publication. It checks distinguishable contributions from clients with 32-, 128- and 512-frame periods, rather than accepting a present mixed-frame tag as proof that every client's audio arrived. The hardware period is 32. Common physical safety offsets cancel in the comparison and are omitted from the model.

The positive design requires:

1. Client periods remain integer multiples of the hardware period, on a common cycle grid.
2. At each relevant boundary, prior capture publication completes before the next client read, and the prior completed mix is visible before hardware consumes it.
3. Copying and mixing fit inside the producer budget. A separate mixer cannot be treated as free work after that budget expires.
4. Joining clients are activated on the shared grid with explicit frame membership. Removing a client does not invalidate other clients' contributions.

Under those conditions, the model passes with 32 + 32 frames, including simultaneous clients and aligned joins/removals. The model's removal semantics drain frames already produced for future playback; it does not model immediate stop/mute semantics.

One frame of client phase displacement breaks the same lower-margin design when producers use nearly their entire budgets. An initially aligned 47-frame client also fails because subsequent cycles do not remain on the 32-frame grid. The existing 64 + 64 frame equivalent passes the corresponding controls. These are model counterexamples, not observed live dropouts or measurements of macOS's internal mixer.

Small guards can work if both phase uncertainty and completion headroom are bounded. Adding a guard without reserving completion headroom is insufficient: a small phase displacement can move a consumer before the previous whole-block publication. The guard experiments include separate final-mix cost controls. No measured bound on arbitrary clients has been established that would justify selecting such a mode in production.

For example, 40 + 40 frames would add 0.833 ms at 96 kHz. In the model this passes with client phase constrained to ±8 frames, capture publication within 24 frames, and each client's contribution published within `C - 8` frames with an instantaneous final mixer. With a separate one-frame final mixer, client work must finish within `C - 9`; the completed hardware-sized mix is published at the hardware boundary. All 27 tested independent phase combinations for three clients pass under those conditions; allowing client work through `C - 8` and then adding that mixer fails 19 of the 27 combinations. These are explicit qualification conditions, not measured headroom or a proposed production setting.

## Public API findings

Primary evidence is the installed Apple SDK headers, reviewed locally without network requests. Exact paths, line ranges and header hashes are recorded in `work/coordinated-delivery-audit-20261115/sdk-api-evidence.json`.

| Mechanism | Available control | Missing condition |
|---|---|---|
| `AudioDeviceStartAtTime` | Requests alignment for an owned IOProc; returns the accepted time and may be unsupported. | Does not specify continuing completion-before-read ordering for independently running applications or later joins/resynchronization. |
| Audio workgroups | Associate realtime work with a common scheduling/deadline group. | Membership does not trigger a producer or wait for its completion. Auxiliary-thread guidance assumes that the triggering relationship already exists. |
| `GetZeroTimeStamp`, clock origin and raw clock mode | Provide sample/host-time mapping; raw mode can avoid HAL filtering. | A clock mapping is not a data-ready notification. It does not impose callback ordering. Changing the seed requests resynchronization. |
| `BeginIOOperation` / `EndIOOperation` | Receive host notifications for an IO phase. | No host API was found for requesting that arbitrary DAW/browser rendering run after a physical publication. |
| `IOCycleUsage` | Declares the process's use of the client portion of an IO cycle. | Does not reserve or sequence another application's publications. |

Relevant SDK anchors:

- `CoreAudio/AudioServerPlugIn.h:34–36,79–89`: plug-ins may not call client HAL APIs; the host owns IO scheduling and operations must avoid blocking.
- `CoreAudio/AudioServerPlugIn.h:428–433,987–1014`: zero timestamp period/mapping and resynchronization semantics. The minimum timestamp period of 10,923 frames is not a 32-frame delivery trigger.
- `CoreAudio/AudioServerPlugIn.h:1053–1080,1126–1153`: Begin/End IO notifications.
- `AudioToolbox/AudioWorkInterval.h:8–49` and `os/workgroup_object.h:155–178`: workgroup purpose, existing trigger/deadline assumptions and incompatible membership.
- `CoreAudio/AudioHardware.h:960–965,987–990,1434–1456,1511–1538`: cycle usage, workgroup property and timed-start constraints.

A read-only capability probe found the workgroup property present but not settable on UFX III, ZED-R16 and StudioPatch. `IOCycleUsage` was settable. `AudioDeviceGetNearestStartTime` returned `stop` for the probe, which had no running IOProc; this does **not** establish whether these devices support timed starts for an active caller. The probe made no property writes or IO start/stop calls.

StudioPatch already follows the physical sample/host clock. The current libASPL default uses HAL's simple IIR clock filtering. Changing to raw timestamps or choosing another origin could improve observed phase behavior, but neither supplies the missing ordering contract. A consistent translation of clock coordinates and audio tags does not itself reduce physical round trip.

## Architecture alternatives

**Own one render graph.** Routing inside a graph driven by the physical callback can remove the extra independently scheduled handoff. This is feasible when StudioPatch owns the render participants, for example a cooperative host/plugin design. The reviewed APIs do not let it place arbitrary Safari/Ableton device clients inside that graph.

**Integrate with the physical transport or driver.** Routing at the hardware buffer layer can remove the second HAL-client boundary while preserving a normal HAL endpoint and system mixing. This requires control of the transport or cooperation from the hardware driver. AudioDriverKit alone does not provide a shortcut around an arbitrary existing RME HAL driver. A hardware-specific backend is a separate product/maintenance commitment, not a small generic optimization.

**Take over per-client mixing.** `MixOutput` and libASPL's non-mixing mode expose individual client contributions. Separate tagged buffers could make readiness explicit and isolate a late client's missing contribution. This does not make that client produce earlier, does not remove the capture boundary, and adds bounded membership, memory and mixing-cost requirements. It is a potentially useful stability investigation with the current margins, not evidence for 0.667 ms RTL. Partial contributions must never be labelled a completed mix.

**Use a public aggregate or direct hardware mode.** This can remove StudioPatch's virtual transport from the application's path, but does not preserve the current arbitrary virtual-channel routing matrix. Adding a private aggregate behind the same virtual endpoint still retains a handoff; it does not automatically create one jointly driven render graph. The previous bridge/aggregate architecture also had measured added latency, so it is not an assumed improvement.

Waiting or spinning inside one audio callback for another is unsuitable: it consumes the deadline, risks priority inversion, and violates the nonblocking design. Moving 32 frames from each transport margin into each virtual safety offset also leaves total RTL unchanged; `latency-accounting.json` records that arithmetic explicitly.

## Recommendation and qualification boundary

Retain the current production margins. Do not add a low-latency mode selected merely by current client count, a short clean run, workgroup membership or an initially favorable phase. No production change is justified by this investigation.

A future coordination prototype should initially keep the current margins and demonstrate actual **buffer-boundary** phase and completion slack, rather than infer them from `inNow` wake-up timestamps. It must control or account for final mixing cost, client additions/removals, different/variable block lengths and resynchronization. Any proposed lower bound must then pass sample-exact real-handler tests and physical RTL/integrity comparisons under multiple clients and CPU load. If ordering cannot be maintained without constraining arbitrary applications, the generic product should retain its present margin; a dedicated backend or cooperative-host mode should be evaluated as a separate design.

## Local evidence

- `work/coordination-audit-20261115/model.py`, generated model/guard/control JSON and `summary.txt`: executable schedule experiments and their assumptions.
- `work/coordination-audit-20261115/capabilities.cpp` / `capabilities.txt`: read-only Core Audio query.
- `work/coordination-audit-20261115/latency-accounting.json`: transport/safety accounting comparison.
- `work/coordinated-delivery-audit-20261115/sdk-api-evidence.json`: primary SDK references and hashes.

No driver/service installation, audio restart, buffer change, signal generation or new physical RTL measurement was performed for this investigation.
