"""Offline preferences invariants. Fixtures contain no user preferences."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch as mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
import ableton_preferences as prefs

spec = importlib.util.spec_from_file_location("sync_names", Path(__file__).resolve().parents[1] / "Tools/sync-ableton-channel-names.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def integer(value):
    return struct.pack("<I", value)


def fixture():
    schema = b""
    for name, fields in prefs.SCHEMAS.items():
        schema += prefs.tag(name) + integer(0xFFFFFFFF if fields is None else len(fields))
        for key, kind in fields or []:
            schema += prefs.encode_string(key) + (prefs.tag(kind) if isinstance(kind, str) else bytes([kind]))

    def channels():
        # Three historical rows but only two active pairs; sparse IDs are not
        # channel numbers. Preserve dormant labels and disabled activators.
        result = integer(4) + integer(2) + b"\1\0" + integer(2) + b"\0\1" + integer(105)
        for index in (100, 102, 104):
            result += prefs.tag("AudioChannelNames") + integer(index)
            for value in (f"old left {index}", f"old right {index}", f"old stereo {index}"):
                result += prefs.encode_string(value)
        return result + b"\0\0"

    devices = b""
    for index, uid in ((3, "target"), (7, "unrelated")):
        devices += prefs.tag("CoreAudioDevice") + integer(index) + struct.pack("<f", 256)
        devices += channels() * 2 + integer(0) + integer(80) + prefs.encode_string(uid)
    return (b"\xab\x1eVx\x05\x57\x2f\0\0" + prefs.tag("LivePreferences") + integer(len(prefs.SCHEMAS)) + schema +
            b"untouched-prefix" + integer(8) + devices + b"\0\0untouched-trailer")


NAMES = {"inputs": ["Åäö 🎹", "Right", "Same", "Same"], "outputs": ["Monitor L", "Monitor R", "a", "b"]}


class PreferencesTests(unittest.TestCase):
    def test_only_active_target_labels_change_and_round_trip(self):
        original = fixture()
        output, changes = prefs.patch(original, "target", names=NAMES)
        before, after = prefs.parse(original), prefs.parse(output)
        self.assertEqual(len(changes), 12)
        a, b = before["unrelated"], after["unrelated"]
        self.assertEqual(original[a.start:a.end], output[b.start:b.end])
        self.assertEqual(after["target"].inputs.rows[0][1][0].value, "Åäö 🎹")
        self.assertEqual(after["target"].inputs.rows[1][1][2].value, "Same")
        self.assertEqual([s.value for s in after["target"].outputs.rows[0][1]], ["", "", "Monitor"])
        self.assertEqual([s.value for s in before["target"].inputs.rows[2][1]],
                         [s.value for s in after["target"].inputs.rows[2][1]])
        self.assertEqual(prefs.patch(output, "target", names=NAMES), (output, []))
        restored, _ = prefs.patch(output, "target", restore=original)
        self.assertEqual(restored, original)

    def test_restore_preserves_later_unrelated_edits(self):
        original = fixture()
        output, _ = prefs.patch(original, "target", names=NAMES)
        output = output.replace(b"untouched-trailer", b"new-unrelated-settings")
        restored, _ = prefs.patch(output, "target", restore=original)
        self.assertEqual(restored, original.replace(b"untouched-trailer", b"new-unrelated-settings"))

    def test_stereo_pairs_clear_mono_labels_without_merging_unrelated_names(self):
        for left, right, stereo in (
            ("Timeline L", "Timeline R", "Timeline"),
            ("A&H Master L (analog)", "A&H Master R (analog)", "A&H Master (analog)"),
            ("Synth l", "Synth r", "Synth"),
        ):
            with self.subTest(left=left, right=right):
                self.assertEqual(prefs.pair_labels(left, right), ["", "", stereo])
        for left, right in (
            ("RE-201", "Minitaur"), ("Synth L", "Other R"),
            ("Synth R", "Synth L"), ("SynthL", "SynthR"),
            ("Synth L (analog)", "Synth R (digital)"),
        ):
            with self.subTest(left=left, right=right):
                self.assertEqual(prefs.pair_labels(left, right), [left, right, f"{left} / {right}"])

    def test_numbered_pairs_keep_mono_names_and_shorten_stereo(self):
        for left, right, stereo in (
            ("Analog 7", "Analog 8", "Analog 7/8"),
            ("UFX III · MADI 9", "UFX III · MADI 10", "UFX III · MADI 9/10"),
            ("Analog 7", "Digital 8", "Analog 7 / Digital 8"),
            ("Analog 7", "Analog 7", "Analog 7"),
        ):
            with self.subTest(left=left, right=right):
                self.assertEqual(prefs.pair_labels(left, right), [left, right, stereo])
        original = fixture()
        names = dict(NAMES, inputs=["Analog 7", "Analog 8", "Timeline L", "Timeline R"])
        output, _ = prefs.patch(original, "target", names=names)
        rows = prefs.parse(output)["target"].inputs.rows
        self.assertEqual([s.value for s in rows[0][1]], ["Analog 7", "Analog 8", "Analog 7/8"])
        self.assertEqual([s.value for s in rows[1][1]], ["", "", "Timeline"])
        self.assertEqual(prefs.patch(output, "target", names=names), (output, []))
        self.assertEqual(prefs.patch(output, "target", restore=original)[0], original)

    def test_reject_schema_change_truncation_and_wrong_width(self):
        original = fixture()
        bad_schema = original.replace(prefs.encode_string("MonoL"), prefs.encode_string("Other"), 1)
        for value in (bad_schema, original[:100], original[:-100]):
            with self.assertRaises((prefs.FormatError, UnicodeError)):
                prefs.patch(value, "target", names=NAMES)
        for values in (["x", "y"], ["x"]):
            with self.assertRaises(prefs.FormatError):
                prefs.patch(original, "target", names=dict(NAMES, inputs=values))

    def test_atomic_write_has_exact_backup_and_preserves_mode(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "Preferences.cfg"
            path.write_bytes(fixture())
            path.chmod(0o640)
            original = path.read_bytes()
            output, _ = prefs.patch(original, "target", names=NAMES)
            backup = sync.atomic_update(path, original, output, Path(root), lambda: True)
            self.assertEqual(path.read_bytes(), output)
            self.assertEqual(backup.read_bytes(), original)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_live_start_or_file_change_aborts_write(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "Preferences.cfg"
            original = fixture()
            output, _ = prefs.patch(original, "target", names=NAMES)
            path.write_bytes(original)
            with self.assertRaises(prefs.FormatError):
                sync.atomic_update(path, original, output, Path(root), lambda: False)
            self.assertEqual(path.read_bytes(), original)

            def concurrent_save():
                path.write_bytes(b"new save from Live")
                return True

            with self.assertRaises(prefs.FormatError):
                sync.atomic_update(path, original, output, Path(root), concurrent_save)
            self.assertEqual(path.read_bytes(), b"new save from Live")
            self.assertEqual(list(Path(root).glob(".channel-names-*")), [])

    def test_default_follows_active_preset_uid(self):
        from types import SimpleNamespace
        import contextlib
        import io
        for uid in ("se.studiopatch.device.v1", "se.studiopatch.preset.test-a"):
            with self.subTest(uid=uid), tempfile.TemporaryDirectory() as root:
                path = Path(root) / "Preferences.cfg"
                original = fixture().replace(prefs.encode_string("target"), prefs.encode_string(uid))
                path.write_bytes(original)
                args = SimpleNamespace(helper=Path("unused"), watch=None, preferences=path,
                                       device_uid=None, restore=None, apply=False)
                snapshot = {"liveRunning": False, "devices": [dict(NAMES, uid=uid)]}
                with mock.object(sync, "helper_json", side_effect=[False, snapshot]), contextlib.redirect_stdout(io.StringIO()):
                    self.assertIn("Preview: 12 labels", sync.sync(args))
                self.assertEqual(path.read_bytes(), original)
                snapshot["devices"].append(dict(NAMES, uid="se.studiopatch.preset.other"))
                with mock.object(sync, "helper_json", side_effect=[False, snapshot]):
                    with self.assertRaises(prefs.FormatError):
                        sync.sync(args)

    def test_running_live_skips_without_reading_preferences(self):
        from types import SimpleNamespace
        args = SimpleNamespace(helper=Path("not-called"), watch=10)
        with mock.object(sync, "helper_json", return_value=True):
            self.assertIn("running", sync.sync(args))


if __name__ == "__main__":
    unittest.main()
