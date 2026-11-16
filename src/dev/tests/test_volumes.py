import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkpoints
import volumes


def prefix(path):
    with open(path, 'rb') as stream: return stream.read(5)


class VolumeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.vm = self.root / 'OmacVM Test-data'
        self.vm.mkdir()
        for name, content in {'guest-os':'ubuntu', 'disk.img':'system', 'efi-vars.fd':'firmware',
                              'vm.env':"NAME='Data'\nVM_USER=ubuntu\nSSH_PORT=52223\nCPUS=2\nMEM_MB=4096\n"}.items():
            (self.vm / name).write_text(content)

    def create(self):
        return volumes.create(self.vm, 'Personal', 4)

    def prepare(self, record):
        with mock.patch('volumes.maintenance', return_value='ready') as maintenance:
            volumes.prepare(self.vm, record['id'], ['Projects', 'Documents'])
        return maintenance

    def test_data_is_outside_vm_and_survives_vm_deletion(self):
        record = self.create(); self.prepare(record)
        disk = volumes.volume(self.vm, record['id'])[0] / 'data.img'
        shutil.rmtree(self.vm)
        other = self.root / 'OmacVM Test-other'; shutil.copytree(self.fixture(), other)
        with mock.patch('volumes.maintenance', return_value='ready'):
            volumes.prepare(other, record['id'], ['Projects'])
        self.assertTrue(disk.exists())
        self.assertEqual(volumes.attached(other)[1]['attached_vm'], str(other))

    def fixture(self):
        vm = self.root / 'template'; vm.mkdir()
        for name, text in {'guest-os':'ubuntu', 'disk.img':'system', 'vm.env':"VM_USER=ubuntu\nSSH_PORT=52223\n"}.items():
            (vm / name).write_text(text)
        return vm

    def test_one_owner_missing_disk_and_unprepared_start_are_refused(self):
        record = self.create(); self.prepare(record)
        other = self.root / 'OmacVM Test-other'; shutil.copytree(self.vm, other)
        (other / volumes.BINDING).unlink()
        with mock.patch('volumes.maintenance'):
            volumes.prepare(other, record['id'], ['Projects'])
        self.assertFalse((self.vm / volumes.BINDING).exists())
        self.assertEqual(volumes.attached(other)[1]['attached_vm'], str(other))
        self.prepare(record)
        binding = self.vm / volumes.BINDING
        binding.write_text(json.dumps({'schema':1, 'id':record['id'], 'ready':False}))
        with self.assertRaisesRegex(ValueError, 'finish'): volumes.arguments(self.vm)
        (volumes.volume(self.vm, record['id'])[0] / 'data.img').unlink()
        with self.assertRaisesRegex(ValueError, 'missing'): volumes.arguments(self.vm)

    def test_running_owner_refuses_all_mutations(self):
        record = self.create(); self.prepare(record)
        with mock.patch('volumes.rt.disk_busy', return_value=True), mock.patch('volumes.maintenance') as maintenance:
            for operation in (lambda: volumes.prepare(self.vm, record['id'], ['Projects']),
                              lambda: volumes.detach(self.vm),
                              lambda: volumes.snapshot(self.vm, record['id'], 'Busy')):
                with self.assertRaisesRegex(ValueError, 'stop'): operation()
            maintenance.assert_not_called()

    def test_handover_refuses_a_running_previous_owner_without_changes(self):
        record = self.create(); self.prepare(record)
        other = self.root / 'OmacVM Test-other'; shutil.copytree(self.fixture(), other)
        with mock.patch('volumes.rt.disk_busy', side_effect=lambda vm: vm == self.vm), mock.patch('volumes.maintenance') as maintenance:
            with self.assertRaisesRegex(ValueError, 'stop'): volumes.prepare(other, record['id'], ['Projects'])
            maintenance.assert_not_called()
        self.assertEqual(volumes.attached(self.vm)[1]['id'], record['id'])
        self.assertFalse((other / volumes.BINDING).exists())

    def test_interrupted_setup_cannot_reformat_on_retry(self):
        record = self.create()
        with mock.patch('volumes.maintenance', side_effect=RuntimeError('interrupted')):
            with self.assertRaises(RuntimeError): volumes.prepare(self.vm, record['id'], ['Projects'])
        with self.assertRaisesRegex(ValueError, 'finish'): volumes.arguments(self.vm)
        retry = self.prepare(record)
        self.assertIn(' recover', retry.call_args.args[1])
        self.assertNotIn(' initialize', retry.call_args.args[1])

    def test_data_snapshots_restore_and_fork_independently(self):
        record = self.create(); self.prepare(record)
        folder, _ = volumes.volume(self.vm, record['id'])
        with open(folder / 'data.img', 'r+b') as stream: stream.write(b'first')
        saved = volumes.snapshot(self.vm, record['id'], 'First')
        with open(folder / 'data.img', 'r+b') as stream: stream.write(b'later')
        child = volumes.fork(self.vm, record['id'], saved['snapshot_id'], 'Agent')
        self.assertIsNone(child['attached_vm'])
        self.assertEqual(child['filesystem_id'], record['id'])
        self.assertEqual(prefix(volumes.volume(self.vm, child['id'])[0] / 'data.img'), b'first')
        with self.assertRaisesRegex(ValueError, 'detach'): volumes.restore(self.vm, record['id'], saved['snapshot_id'])
        with mock.patch('volumes.maintenance'): volumes.detach(self.vm)
        restored = volumes.restore(self.vm, record['id'], saved['snapshot_id'])
        self.assertEqual(prefix(folder / 'data.img'), b'first')
        before = folder / 'snapshots' / restored['preserved'] / 'data.img'
        self.assertEqual(prefix(before), b'later')

    def test_system_restore_preserves_attachment_and_requires_repair(self):
        record = self.create(); self.prepare(record)
        with mock.patch('checkpoints.rt.runtime_identity', return_value='runtime'):
            saved = checkpoints.create(self.vm, 'System')
            source, _ = checkpoints.checkpoint(self.vm, saved['id'])
            self.assertFalse((source / 'vm' / volumes.BINDING).exists())
            self.assertEqual(saved['personal_data'], 'excluded')
            checkpoints.restore(self.vm, saved['id'])
            self.assertEqual(volumes.attached(self.vm, ready=False)[1]['id'], record['id'])
            with self.assertRaisesRegex(ValueError, 'finish'): volumes.arguments(self.vm)
            self.prepare(record)
            self.assertTrue(volumes.arguments(self.vm))

    def test_metadata_and_lock_symlinks_are_not_followed(self):
        record = self.create(); folder, _ = volumes.volume(self.vm, record['id'])
        (folder / 'data.img').unlink()
        (folder / 'data.img').symlink_to(self.vm / 'disk.img')
        with self.assertRaises(ValueError): volumes.volume(self.vm, record['id'])
        (volumes.store(self.vm) / 'registry.lock').symlink_to(self.vm / 'disk.img')
        with self.assertRaises(OSError):
            with volumes.locked(self.vm): pass
        self.assertEqual((self.vm / 'disk.img').read_text(), 'system')
        with self.assertRaises(ValueError): volumes.volume(self.vm, '../outside')


if __name__ == '__main__': unittest.main()
