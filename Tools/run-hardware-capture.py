#!/usr/bin/env python3
"""Run one bounded, unprivileged HAL capture; never install or restart services.

The chosen output receives latency-capture's low-level test signal. Use an
isolated physical loopback. CPU figures are percent of one core, as reported
by ps. A stopped capture is a failure; partial evidence is kept.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def core_audio_cpu():
    result = subprocess.run(["pgrep", "-x", "coreaudiod"], capture_output=True,
                            text=True, timeout=2)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("Cannot monitor coreaudiod")
    result = subprocess.run(["ps", "-p", ",".join(result.stdout.split()),
                             "-o", "pcpu="], capture_output=True, text=True,
                            check=True, timeout=2)
    return sum(float(value) for value in result.stdout.split())


def stop(process):
    if process.poll() is not None:
        return
    # The capture owns this new process group. Never kill other audio clients.
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=2)
    except ProcessLookupError:
        pass


def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--uid", required=True)
    parser.add_argument("--input", type=int, required=True)
    parser.add_argument("--output", type=int, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--buffer", type=int, default=256)
    parser.add_argument("--load", type=float, default=0)
    args = parser.parse_args()
    if not 6 <= args.seconds <= 300 or not 0 <= args.load <= .95:
        parser.error("Use 6..300 seconds and load 0..0.95")
    if args.input < 1 or args.output < 0 or not 1 <= args.buffer <= 4096:
        parser.error("Input must be positive; output 0 disables playback; buffer 1..4096")
    args.prefix.parent.mkdir(parents=True, exist_ok=True)
    if list(args.prefix.parent.glob(args.prefix.name + "-*")):
        parser.error("Prefix already has evidence; choose a new prefix")
    initial_cpu = core_audio_cpu()
    if initial_cpu >= 80:
        raise RuntimeError("Core Audio already uses >=80% of one core; capture not started")
    started = time.monotonic()
    deadline = started + args.seconds + 20
    high_since = None
    error = None
    process = None
    status = Path.home() / "Library/Application Support/StudioPatch/runtime-status.json"
    env = dict(os.environ, STUDIOPATCH_TEST_STREAM="1",
               STUDIOPATCH_TEST_SECONDS=str(args.seconds),
               STUDIOPATCH_TEST_BUFFER=str(args.buffer), STUDIOPATCH_TEST_LOAD=str(args.load))
    try:
        with Path(str(args.prefix) + "-tool.log").open("w") as log, \
             Path(str(args.prefix) + "-status.jsonl").open("w") as history:
            process = subprocess.Popen([str(args.capture.resolve()), args.uid,
                                        str(args.input), str(args.output), str(args.prefix)],
                                       env=env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            while process.poll() is None:
                now = time.monotonic()
                if now > deadline:
                    raise RuntimeError("Capture exceeded duration + 20 second deadline")
                cpu = core_audio_cpu()
                high_since = (high_since if high_since is not None else now) if cpu >= 80 else None
                entry = dict(time=time.time(), coreAudioCPU=cpu)
                try:
                    snapshot = json.loads(status.read_text())
                    entry.update(running=snapshot["running"], message=snapshot["message"],
                                 rate=snapshot["rate"],
                                 diagnostics=json.loads(snapshot.get("latencyDiagnostics") or "{}"))
                except (OSError, ValueError, KeyError):
                    entry["runtimeStatus"] = "unavailable"
                history.write(json.dumps(entry) + "\n")
                history.flush()
                if high_since is not None and now - high_since >= 10:
                    raise RuntimeError("Core Audio remained >=80% of one core for 10 seconds")
                time.sleep(.5)
            if process.returncode:
                raise RuntimeError(f"Capture exited {process.returncode}")
    except (Exception, KeyboardInterrupt) as exc:
        error = str(exc) or "Interrupted"
    finally:
        if process is not None:
            stop(process)
        result = dict(completed=error is None, error=error,
                      elapsed=time.monotonic()-started,
                      captureExit=process.returncode if process is not None else None)
        Path(str(args.prefix) + "-runner.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    # Completion only verifies acquisition. Analyze timestamps and compare the
    # captured waveform separately before calling an audio test a pass.
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
