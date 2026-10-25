"""Exercise the bundled native adapter against the established Python adapter."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from AbletonNamesTests import fixture, NAMES, prefs

BINARY = Path(sys.argv.pop(1)).resolve()

class NativeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'Preferences.cfg'
        self.original = fixture()
        self.path.write_bytes(self.original)
        self.path.chmod(0o640)

    def run_tool(self, names=NAMES, **options):
        request = dict(preferences=str(self.path), deviceUID='target', deviceName='StudioPatch (Test preset)', apply=True)
        request.update(options.pop('request', {}))
        payload = dict(request=request, **names, state=str(self.root/'state'), **options)
        return json.loads(subprocess.run([str(BINARY)], input=json.dumps(payload), text=True,
                                         capture_output=True, timeout=10, check=True).stdout)

    def test_parity_backup_idempotence_and_unrelated_settings(self):
        expected, changes = prefs.patch(self.original, 'target', names=NAMES)
        result = self.run_tool()
        self.assertTrue(result['success'], result)
        self.assertEqual(self.path.read_bytes(), expected)
        self.assertEqual(Path(result['backup']).read_bytes(), self.original)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o640)
        self.assertEqual(Path(result['backup']).stat().st_mode & 0o777, 0o600)
        result = self.run_tool()
        self.assertTrue(result['success'])
        self.assertIn('already up to date', result['message'])
        self.assertEqual(len(list((self.root/'state/Backups').glob('*.cfg'))), 1)

    def test_pair_naming_matches_existing_script(self):
        for left, right in [('Timeline L','Timeline R'), ('A&H Master L (analog)','A&H Master R (analog)'),
                            ('Synth l','Synth r'), ('RE-201','Minitaur'), ('SynthL','SynthR'),
                            ('Synth L (analog)','Synth R (digital)'), ('Analog 7','Analog 8'),
                            ('UFX III · MADI 9','UFX III · MADI 10'), ('Same','Same')]:
            self.path.write_bytes(self.original)
            names=dict(inputs=[left,right,'Åäö 🎹','右'],outputs=NAMES['outputs'])
            result=self.run_tool(names)
            self.assertTrue(result['success'], result)
            self.assertEqual(self.path.read_bytes(), prefs.patch(self.original,'target',names=names)[0])

    def test_missing_device_has_full_preset_name(self):
        result=self.run_tool(request=dict(deviceUID='not-saved'))
        self.assertFalse(result['success'])
        self.assertIn('StudioPatch (Test preset)', result['message'])
        self.assertIn('select', result['message'])
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_wrong_counts_rejected(self):
        for count in [1,2,6]:
            result=self.run_tool(dict(NAMES,inputs=['x']*count))
            self.assertFalse(result['success'])
            self.assertEqual(self.path.read_bytes(),self.original)

    def test_missing_file_and_symlink(self):
        self.path.unlink()
        result=self.run_tool()
        self.assertFalse(result['success'])
        self.assertIn('not found',result['message'])
        target=self.root/'other.cfg'; target.write_bytes(self.original)
        self.path.symlink_to(target)
        self.assertFalse(self.run_tool()['success'])
        self.assertEqual(target.read_bytes(),self.original)

    def test_running_and_starting_live_never_write(self):
        for check in [1,2,3]:
            result=self.run_tool(runningAt=check)
            self.assertFalse(result['success'],result)
            self.assertIn('Ableton',result['message'])
            self.assertEqual(self.path.read_bytes(),self.original)
        self.path.unlink()
        self.assertIn('running',self.run_tool(runningAt=1)['message'])

    def test_concurrent_save_is_preserved(self):
        result=self.run_tool(changeAt=3)
        self.assertFalse(result['success'])
        self.assertEqual(self.path.read_bytes(),b'Concurrent save')
        self.assertEqual(list(self.root.glob('.channel-names-*')),[])

    def test_preview_and_format_rejection(self):
        self.assertTrue(self.run_tool(request=dict(apply=False))['success'])
        self.assertEqual(self.path.read_bytes(),self.original)
        self.assertFalse((self.root/'state/Backups').exists())
        bad=self.original.replace(prefs.encode_string('MonoL'),prefs.encode_string('Other'),1)
        for data in [bad,self.original[:100],self.original[:-100],b'not preferences']:
            self.path.write_bytes(data)
            self.assertFalse(self.run_tool()['success'])
            self.assertEqual(self.path.read_bytes(),data)

if __name__ == '__main__':
    unittest.main()
