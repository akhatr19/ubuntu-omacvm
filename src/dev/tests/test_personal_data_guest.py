"""Formatting is allowed only for a new, unsigned disk with the expected serial."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock

source = Path(__file__).resolve().parents[2] / 'ubuntu/guest/personal-data.py'
spec = importlib.util.spec_from_file_location('personal_data_guest', source)
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)


class GuestDataSafetyTests(unittest.TestCase):
    config = {'id':'a' * 32, 'user':'ubuntu', 'folders':['Projects']}

    def test_existing_wrong_uuid_is_never_formatted(self):
        for mode in ('initialize', 'recover', 'attach', 'boot'):
            with self.subTest(mode=mode), mock.patch.object(guest, 'account', return_value=(mock.Mock(), Path('/home/ubuntu'))), mock.patch.object(guest, 'run') as run, \
                 mock.patch.object(Path, 'exists', return_value=True), \
                 mock.patch.object(guest.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'different-uuid', '')):
                with self.assertRaisesRegex(ValueError, 'UUID differs'): guest.mount(self.config, mode)
                self.assertFalse(any(call.args[0] == 'mkfs.ext4' for call in run.call_args_list))

    def test_recovery_never_formats_an_unsigned_disk(self):
        with mock.patch.object(guest, 'account', return_value=(mock.Mock(), Path('/home/ubuntu'))), mock.patch.object(guest, 'run') as run, \
             mock.patch.object(Path, 'exists', return_value=True), \
             mock.patch.object(guest.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2, '', '')):
            with self.assertRaisesRegex(ValueError, 'UUID differs'): guest.mount(self.config, 'recover')
            self.assertFalse(any(call.args[0] == 'mkfs.ext4' for call in run.call_args_list))

    def test_unsigned_disk_with_other_signatures_is_never_formatted(self):
        def run(*args):
            if args[0] == 'wipefs': return '{"signatures":[{"type":"gpt"}]}'
            return ''
        with mock.patch.object(guest, 'account', return_value=(mock.Mock(), Path('/home/ubuntu'))), mock.patch.object(guest, 'run', side_effect=run) as command, \
             mock.patch.object(Path, 'exists', return_value=True), \
             mock.patch.object(guest.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2, '', '')):
            with self.assertRaisesRegex(ValueError, 'already has'): guest.mount(self.config, 'initialize')
            self.assertFalse(any(call.args[0] == 'mkfs.ext4' for call in command.call_args_list))


if __name__ == '__main__': unittest.main()
