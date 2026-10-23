# Development history

These are dated engineering records from the development of StudioPatch 0.1 and 0.2. They are kept because they explain *why* the current design looks the way it does, including rejected approaches and failed experiments.

**They are not current instructions.** Many describe superseded behavior (manual Start/Stop, a hidden bridge device, ad hoc signing, "Follow clock master", file-based presets). For the current state, start at the [documentation index](../README.md).

Paths such as `work/…` and `/tmp/…` refer to raw evidence (captures, logs, backups) on the original development machine. That evidence is not part of the repository.

| Record | What it covers |
|---|---|
| [VERIFICATION-2026-10-22.md](VERIFICATION-2026-10-22.md) | Chronological verification log from the first prototype to version 0.2.0: UI features, HAL deadlocks, signing and permissions, first Ableton tests. |
| [BACKGROUND-RUNTIME.md](BACKGROUND-RUNTIME.md) | Original requirements for moving the audio engine into a background service. |
| [LATENCY-REVIEW-2026-10-23.md](LATENCY-REVIEW-2026-10-23.md) | First read-only latency review of the hidden-bridge design. |
| [LATENCY-PLAN.md](LATENCY-PLAN.md) | Staged latency plan and acceptance gates written before the direct transport existed. |
| [LATENCY-MEASUREMENT-2026-10-23.md](LATENCY-MEASUREMENT-2026-10-23.md) | Version 0.1.1: directional latency reporting and its physical verification. |
| [LATENCY-DIRECT-2026-10-23.md](LATENCY-DIRECT-2026-10-23.md) | Version 0.2.0: the direct shared-memory transport and its first measurements. |
| [REVIEW-ACTIONS-2026-10-23.md](REVIEW-ACTIONS-2026-10-23.md) | Closure of the architecture review: all 19 findings (C1–L4) and their dispositions. |
| [REVIEW-HISTORY-2026-10-23.md](REVIEW-HISTORY-2026-10-23.md) | Full chronological evidence behind the architecture review, including failed runs. |
| [LATENCY-BASELINE-SHA256.txt](LATENCY-BASELINE-SHA256.txt) | Source checksums for the reviewed latency baseline. |

The README before the documentation restructuring (with the full historical feature notes) is available in git history at commit `8e55e66`.
