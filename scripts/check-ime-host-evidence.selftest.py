#!/usr/bin/env python3
"""Offline replay of restored-document and input-source attribution failures."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('host_evidence', Path(__file__).with_name('check-ime-host-evidence.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HostEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.binding = dict(pid=100, launched=10, executable='/TextEdit', window=12,
                            title='old.rtf', document='file:///test/old.rtf')
        self.before = dict(binding=copy.deepcopy(self.binding), frontPID=100, focused=True,
                           source='im.owltype.inputmethod.Owltype.Hans', observedAt=110, nihaoCount=3)
        self.after = copy.deepcopy(self.before)
        self.after['observedAt'] = 112
        self.after['nihaoCount'] = 4
        self.baseline = dict(mtime_ns=90, nihao_count=3)
        self.saved = dict(mtime_ns=111, mtime=111, nihao_count=4)

    def errors(self, role='old'):
        return module.validate(self.binding, self.before, self.after, self.baseline, self.saved, 95, 100, role)

    def test_original_old_process_passes(self):
        self.assertEqual(self.errors(), [])

    def test_restored_old_document_in_new_process_rejected(self):
        # Same name, URL and text, but exactly the wrong-host regression observed live.
        for item in (self.before, self.after):
            item['binding']['pid'] = 200
            item['binding']['launched'] = 105
            item['frontPID'] = 200
        self.assertTrue(self.errors())

    def test_pid_reuse_rejected(self):
        self.after['binding']['launched'] = 105
        self.assertTrue(self.errors())

    def test_reopened_window_rejected(self):
        self.after['binding']['window'] = 99
        self.assertTrue(self.errors())

    def test_other_source_cannot_pass(self):
        self.before['source'] = 'com.tencent.inputmethod.wetype.pinyin'
        self.assertTrue(self.errors())

    def test_focus_change_cannot_pass(self):
        self.after['focused'] = False
        self.assertTrue(self.errors())

    def test_old_text_without_new_commit_cannot_pass(self):
        self.saved['nihao_count'] = 3
        self.assertTrue(self.errors())

    def test_late_save_cannot_pass(self):
        self.after['observedAt'] = 161
        self.assertTrue(self.errors())

    def test_save_before_observation_cannot_pass(self):
        self.saved['mtime'] = 109
        self.assertTrue(self.errors())

    def test_new_host_must_start_after_install(self):
        self.assertTrue(self.errors('new'))
        self.binding['launched'] = 105
        for item in (self.before, self.after):
            item['binding']['launched'] = 105
        self.assertEqual(self.errors('new'), [])

    def test_host_launched_during_install_is_not_old(self):
        self.binding['launched'] = 97
        for item in (self.before, self.after):
            item['binding']['launched'] = 97
        self.assertTrue(self.errors())

    def test_another_process_saved_same_path_rejected(self):
        self.after['nihaoCount'] = 3
        self.assertTrue(self.errors())

    def replay_main(self, source):
        self.before['source'] = source
        with tempfile.TemporaryDirectory() as folder:
            binding = Path(folder) / 'binding.json'
            binding.write_text(json.dumps(self.binding))
            output = Path(folder) / 'evidence.json'
            argv = ['watch', '--helper', '/fake/helper', '--binding', str(binding),
                    '--started', '95', '--completed', '100', '--role', 'old', '--output', str(output)]

            def capture(command, **kwargs):
                Path(command[-1]).write_bytes(b'isolated screenshot fixture')

            with patch('sys.argv', argv), patch.object(module, 'file_state', side_effect=[self.baseline, self.saved]), \
                 patch.object(module.subprocess, 'check_output', side_effect=[json.dumps(self.before), json.dumps(self.before), json.dumps(self.after)]), \
                 patch.object(module.subprocess, 'run', side_effect=capture) as screenshot, \
                 patch.object(module.time, 'sleep'), patch.object(module.time, 'time', return_value=110):
                if source == 'im.owltype.inputmethod.Owltype.Hans':
                    module.main()
                    self.assertEqual(json.loads(output.read_text())['errors'], [])
                    screenshot.assert_called_once()
                else:
                    with self.assertRaises(ValueError):
                        module.main()
                    self.assertTrue(json.loads(output.read_text())['errors'])
                    screenshot.assert_not_called()

    def test_full_watch_flow_without_live_effects(self):
        self.replay_main('im.owltype.inputmethod.Owltype.Hans')

    def test_full_watch_flow_rejects_other_ime(self):
        self.replay_main('com.tencent.inputmethod.wetype.pinyin')

    def test_save_between_file_read_and_host_observation(self):
        # Native failure: the file read still saw the old mtime, then a save
        # completed 13ms before the following AX observation. That observation
        # must not replace the earlier boundary for the next file read.
        with tempfile.TemporaryDirectory() as folder:
            binding = Path(folder) / 'binding.json'
            binding.write_text(json.dumps(self.binding))
            output = Path(folder) / 'evidence.json'
            reads = [0]

            def state(_):
                reads[0] += 1
                return copy.deepcopy(self.saved if reads[0] >= 3 else self.baseline)

            def observation(*args, **kwargs):
                value = copy.deepcopy(self.before)
                value['observedAt'] = {1: 110, 2: 111.013, 3: 111.3}[reads[0]]
                value['nihaoCount'] = 3 if reads[0] == 1 else 4
                return json.dumps(value)

            def capture(command, **kwargs):
                Path(command[-1]).write_bytes(b'isolated screenshot fixture')

            argv = ['watch', '--helper', '/fake/helper', '--binding', str(binding),
                    '--started', '95', '--completed', '100', '--role', 'old', '--output', str(output)]
            with patch('sys.argv', argv), patch.object(module, 'file_state', side_effect=state), \
                 patch.object(module.subprocess, 'check_output', side_effect=observation), \
                 patch.object(module.subprocess, 'run', side_effect=capture), \
                 patch.object(module.time, 'sleep'), patch.object(module.time, 'time', return_value=110):
                module.main()
            self.assertEqual(json.loads(output.read_text())['errors'], [])


if __name__ == '__main__':
    unittest.main()
