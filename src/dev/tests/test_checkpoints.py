import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkpoints


class CheckpointTests(unittest.TestCase):
    def fixture(self, root):
        vm = root / 'OmacVM Test-history'; vm.mkdir()
        for name, text in {'guest-os':'ubuntu', 'vm.env':"NAME='History'\nSSH_PORT=52222\nCPUS=2\nMEM_MB=4096\nVM_USER=ubuntu\n", 'disk.img':'state-one', 'efi-vars.fd':'firmware', 'ssh-key':'private', 'ssh-key.pub':'public'}.items():
            (vm / name).write_text(text)
        return vm

    def test_create_restore_preserves_current_state_and_tree(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch('checkpoints.rt.runtime_identity', return_value='runtime'):
            vm = self.fixture(Path(directory))
            first = checkpoints.create(vm, 'First')
            self.assertEqual((vm / 'disk.img').read_text(), 'state-one')
            (vm / 'disk.img').write_text('state-two')
            result = checkpoints.restore(vm, first['id'])
            self.assertEqual((vm / 'disk.img').read_text(), 'state-one')
            saved, _ = checkpoints.checkpoint(vm, result['preserved'])
            self.assertEqual((saved / 'vm/disk.img').read_text(), 'state-two')
            listing = checkpoints.listing(vm)
            self.assertEqual(listing['head'], first['id'])
            self.assertEqual(len(listing['checkpoints']), 2)
            self.assertEqual((saved / 'vm/disk.img').stat().st_mode & 0o777, 0o400)

    def test_fork_has_fresh_keys_port_and_parent_and_can_checkpoint_again(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch('checkpoints.rt.runtime_identity', return_value='runtime'):
            vm = self.fixture(Path(directory)); first = checkpoints.create(vm, 'Base')
            child = Path(checkpoints.fork(vm, first['id'], 'experiment')['folder'])
            self.assertEqual((child / 'disk.img').read_text(), 'state-one')
            self.assertNotEqual((child / 'ssh-key').read_text(), 'private')
            self.assertNotIn('SSH_PORT=52222\n', (child / 'vm.env').read_text())
            self.assertTrue((child / 'fork-identity').exists())
            second = checkpoints.create(child, 'Experiment')
            self.assertEqual(second['parent'], first['id'])
            self.assertNotEqual(second['branch'], first['branch'])
            self.assertEqual(len(checkpoints.listing(vm)['checkpoints']), 2)
            with self.assertRaises(ValueError): checkpoints.fork(vm, first['id'], 'experiment')

    def test_cross_branch_restore_keeps_local_identity_and_host_grants(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch('checkpoints.rt.runtime_identity', return_value='runtime'):
            vm = self.fixture(Path(directory)); first = checkpoints.create(vm, 'Base')
            child = Path(checkpoints.fork(vm, first['id'], 'experiment')['folder'])
            (child / 'disk.img').write_text('branch-data')
            branch = checkpoints.create(child, 'Branch')
            (vm / 'mac-folder').write_text('/local/selected-folder')
            checkpoints.restore(vm, branch['id'])
            self.assertEqual((vm / 'disk.img').read_text(), 'branch-data')
            self.assertEqual((vm / 'ssh-key').read_text(), 'private')
            self.assertIn("NAME='History'", (vm / 'vm.env').read_text())
            self.assertEqual((vm / 'mac-folder').read_text(), '/local/selected-folder')
            self.assertTrue((vm / 'fork-identity').exists())

    def test_external_links_and_invalid_ids_are_never_followed(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch('checkpoints.rt.runtime_identity', return_value='runtime'):
            root = Path(directory); vm = self.fixture(root)
            (vm / 'outside').symlink_to(root / 'secret')
            with self.assertRaisesRegex(ValueError, 'symlink'): checkpoints.create(vm, 'No external data')
            with self.assertRaises(ValueError): checkpoints.checkpoint(vm, '../outside')
            self.assertEqual((vm / 'disk.img').read_text(), 'state-one')

    def test_failed_atomic_swap_keeps_original_disk(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch('checkpoints.rt.runtime_identity', return_value='runtime'):
            vm = self.fixture(Path(directory)); first = checkpoints.create(vm, 'First')
            (vm / 'disk.img').write_text('state-two')
            with mock.patch('checkpoints.exchange', side_effect=OSError('unsupported')), self.assertRaises(OSError):
                checkpoints.restore(vm, first['id'])
            self.assertEqual((vm / 'disk.img').read_text(), 'state-two')


if __name__ == '__main__': unittest.main()
