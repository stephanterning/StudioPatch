#!/usr/bin/env python3
"""Copy Core Audio names into a closed Live's saved preferences."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from ableton_preferences import FormatError, patch


STATE = Path.home() / "Library/Application Support/AbletonChannelNames"


def helper_json(helper, mode):
    result = subprocess.run([str(helper), mode], check=True, capture_output=True, text=True, timeout=20)
    return json.loads(result.stdout)


def preferences_path(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = str(info.get("CFBundleShortVersionString", ""))
    match = re.match(r"^(12\.\d+\.\d+)(?:\s|$)", version)
    if not match:
        raise FormatError(f"Unsupported installed Live version: {version!r}")
    return Path.home() / "Library/Preferences/Ableton" / f"Live {match[1]}" / "Preferences.cfg"


def atomic_update(path, before, after, state, stopped):
    """Caller holds our advisory lock. Live doesn't honor that lock, so recheck.

    No atomic transaction with Live's process startup exists. Do not launch Live
    during this short write; the watcher also waits for a stable stopped state.
    """
    original = path.lstat()
    if not stat.S_ISREG(original.st_mode):
        raise FormatError("Preferences must be a regular file, not a symlink")
    backup_dir = state / "Backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / f"{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex}.cfg"
    with backup.open("xb") as stream:
        os.chmod(backup, 0o600)
        stream.write(before)
        stream.flush()
        os.fsync(stream.fileno())
    if backup.read_bytes() != before:
        raise OSError("Backup verification failed")
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".channel-names-", dir=path.parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(after)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), stat.S_IMODE(original.st_mode))
        if not stopped():
            raise FormatError("Live started during preparation; no preferences written")
        current = path.lstat()
        if (current.st_ino, current.st_mtime_ns, current.st_size) != (original.st_ino, original.st_mtime_ns, original.st_size) or path.read_bytes() != before:
            raise FormatError("Preferences changed during preparation; no preferences written")
        os.replace(temporary, path)
        temporary = None
        if path.read_bytes() != after:
            raise OSError(f"Read-back verification failed. Original backup: {backup}")
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)
    # Receipt is informational; failure cannot undo an already successful write.
    receipt = {"preferences": str(path), "beforeSHA256": hashlib.sha256(before).hexdigest(),
               "afterSHA256": hashlib.sha256(after).hexdigest()}
    try:
        backup.with_suffix(".json").write_text(json.dumps(receipt, indent=2) + "\n")
    except OSError as error:
        print(f"Could not save backup receipt: {error}", file=sys.stderr)
    return backup


def sync(args):
    # Do not read hardware or touch preferences while Live is running.
    if helper_json(args.helper, "--running"):
        if args.watch:
            return "Live is running; waiting until it is closed."
        raise FormatError("Live is running; nothing written. Quit Live and run again.")
    path = args.preferences or preferences_path(args.live_app)
    if path.is_symlink():
        raise FormatError("Refusing a symlinked Preferences.cfg")
    before = path.read_bytes()
    device_uid = args.device_uid
    if args.restore:
        if device_uid is None:
            raise FormatError("Choose --device-uid when restoring labels for a specific preset device")
        after, changes = patch(before, device_uid, restore=args.restore.read_bytes())
    else:
        snapshot = helper_json(args.helper, "--snapshot")
        if snapshot["liveRunning"]:
            raise FormatError("Live started; nothing written.")
        matches = [d for d in snapshot["devices"] if
                   d["uid"] == device_uid or (device_uid is None and
                   (d["uid"] == "se.studiopatch.device.v1" or d["uid"].startswith("se.studiopatch.preset.")))]
        if len(matches) != 1:
            raise FormatError(f"Expected one active StudioPatch device or explicit UID {device_uid!r}; found {len(matches)}")
        device_uid = matches[0]["uid"]
        after, changes = patch(before, device_uid, names=matches[0])
    if not changes:
        return "Channel names are already up to date."
    if not args.apply:
        print(f"Preferences: {path}\nDevice UID: {device_uid}")
        for direction, label, old, new in changes:
            print(f"  {direction} {label}: {old!r} → {new!r}")
        return f"Preview: {len(changes)} labels would change. Use --apply to save."
    backup = atomic_update(path, before, after, STATE, lambda: not helper_json(args.helper, "--running"))
    return f"Updated {len(changes)} labels. Live will read them on its next start.\nBackup: {backup}"


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True, help=argparse.SUPPRESS)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="Write names with backup; default is preview only")
    mode.add_argument("--dry-run", action="store_true", help="Preview without writing (default)")
    mode.add_argument("--list", action="store_true", help="List macOS devices and their UIDs/names")
    mode.add_argument("--restore", type=Path, help="Restore this device's labels from a .cfg backup, preserving other settings")
    parser.add_argument("--device-uid", help="Device UID to update (default: active StudioPatch preset)")
    parser.add_argument("--preferences", type=Path, help="Explicit Preferences.cfg; otherwise use installed Live's version")
    parser.add_argument("--live-app", type=Path, default=Path("/Applications/Ableton Live 12 Suite.app"))
    parser.add_argument("--watch", type=float, nargs="?", const=10, help="Sync automatically every N seconds while Live is closed (default 10); Ctrl-C stops")
    args = parser.parse_args()
    if args.watch is not None:
        if args.list or args.dry_run or args.restore or not 5 <= args.watch <= 3600:
            parser.error("--watch requires normal sync and an interval of 5–3600 seconds")
        args.apply = True
    if args.restore:
        args.apply = True
    return args


def main():
    args = arguments()
    if args.list:
        print(json.dumps(helper_json(args.helper, "--list"), ensure_ascii=False, indent=2))
        return
    STATE.mkdir(parents=True, exist_ok=True)
    last_message = None
    stable_stopped = False
    while True:
        try:
            # Wait for two stopped observations after startup/exit before a watch
            # write, so Live has time to finish its final preferences save.
            if args.watch and helper_json(args.helper, "--running"):
                stable_stopped = False
                message = "Live is running; waiting until it is closed."
            elif args.watch and not stable_stopped:
                stable_stopped = True
                message = "Live is closed; waiting one interval before syncing."
            else:
                with (STATE / "sync.lock").open("a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    message = sync(args)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if not args.watch:
                raise
            message = f"Sync deferred: {error}"
        if message != last_message:
            print(message, flush=True)
            last_message = message
        if not args.watch:
            return
        time.sleep(args.watch)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nWatcher stopped.")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
