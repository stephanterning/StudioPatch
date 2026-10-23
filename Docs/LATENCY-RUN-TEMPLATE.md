# Latency experiment run

Copy this template for each run; keep the original blank. Use “not measured” or “unavailable” rather than zero for missing observations. See [LATENCY.md](LATENCY.md#measuring-latency) for the tools.

## Identity and configuration

- Run ID / date / operator:
- Stage / hypothesis / single change under test:
- Baseline or candidate:
- Source snapshot/hash manifest:
- Built app/service hashes and installed driver hash/version:
- macOS / Mac model / power mode:
- Audio interface firmware and driver versions:
- Device UIDs and transport paths:
- Physical clock source and verified lock status:
- Active preset / modified flag / paired session and library backup paths:
- Sample rate:
- DAW/version/project, plug-ins, monitoring and delay compensation settings:
- Client buffer requested / actual:
- Engine buffer requested / actual / observed callback frame sizes:
- Software margin per direction (shown under Advanced) and any test overrides:
- Channel counts, routes, fan-out, inactive routes and display order:
- Sync lock and drift correction setting per secondary interface:
- TotalMix/ZED hardware routing:

## Method

- Physical output → input connection and signal level:
- Speaker/headphone isolation and feedback checks:
- Reference signal / tool / version / correlation or pulse method:
- How raw transport latency is separated from DAW recording compensation:
- Load scenario and reproducible workload:
- Settling window / pulse count / duration / repetition number:
- Counters at start and end; session generation and active client states:
- Raw recordings, logs, probe output and telemetry paths:

## Results

| Metric | Baseline | Candidate | Difference / interpretation |
|---|---|---|---|
| RTL median, frames / ms | not measured | not measured | |
| RTL p95 / p99 / max | not measured | not measured | |
| RTL variation / repeatability | not measured | not measured | |
| Compensated recording offset | not measured | not measured | |
| Capture steady-state misses | not measured | not measured | |
| Playback steady-state misses | not measured | not measured | |
| Startup / idle / intentional mute misses | not measured | not measured | |
| Malformed buffers / stale or unexpected output | not measured | not measured | |
| Callback duration and headroom distributions | not measured | not measured | |
| CPU load and instrumentation overhead | not measured | not measured | |
| Recovery times and outcomes | not measured | not measured | |

Conversion: milliseconds = frames × 1000 / sample rate. Added RTL requires the same physical path and matching workload; do not attribute converter differences to StudioPatch. Cumulative missing-frame counts are not automatically audible glitch counts.

## Decision

- Acceptance thresholds chosen BEFORE comparison:
- Automated tests and exact commands/logs:
- Passed / failed / inconclusive, with evidence:
- Unexplained events or missing metrics:
- Comparison confounders / repeat required:
- Keep experiment / revise / roll back:
- User configuration restored? Active preset and unsaved edits preserved?
- Next step and remaining questions:
