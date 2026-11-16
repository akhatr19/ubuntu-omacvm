import base64
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest import mock

import guests
import homefolders
import runtime
import workspace


class GuestProfilesTests(unittest.TestCase):
    def test_legacy_omarchy_and_unknown_guests_are_distinguished(self):
        with tempfile.TemporaryDirectory() as directory:
            vm = Path(directory)
            self.assertEqual('omarchy', guests.profile(vm))
            (vm / 'guest-os').write_text('custom')
            self.assertFalse(homefolders.enabled(vm))
            (vm / 'guest-os').write_text('unknown-os')
            self.assertEqual('custom', guests.profile(vm))
            (vm / 'guest-os').write_text('omarchy')
            self.assertTrue(homefolders.enabled(vm))

    def test_pinned_runtime_is_selected_and_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'App.app'
            current = app / 'Contents/Resources'
            old = Path(directory) / 'old'
            for root, content in ((current, b'new-runtime'), (old, b'old-runtime')):
                (root / 'runtime/bin').mkdir(parents=True)
                (root / 'firmware').mkdir()
                (root / 'runtime/bin/OmacVM').write_bytes(content)
                (root / 'firmware/edk2-aarch64-code.fd').write_bytes(b'firmware')
            identity = runtime.runtime_identity(old)
            archive = current / 'compat-runtimes' / identity
            shutil.copytree(old, archive)
            with mock.patch.object(runtime, 'app_bundle', return_value=app):
                self.assertEqual(current, runtime.runtime_resources())
                self.assertEqual(archive, runtime.runtime_resources(identity))
                (archive / 'runtime/bin/OmacVM').write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'pinned runtime'): runtime.runtime_resources(identity)

    def test_native_ssh_attestation_rejects_pid_reuse_for_another_vm(self):
        key = 'ssh-ed25519 ' + base64.b64encode(struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes(range(32))).decode()
        with tempfile.TemporaryDirectory() as directory:
            vm = Path(directory)
            (vm / 'logs').mkdir()
            (vm / 'logs/ssh-identity.json').write_text(json.dumps({'schema':1, 'pid':1234, 'key':key}))
            process = mock.Mock(returncode=0, stdout='qemu -drive file=/other/disk.img,format=raw')
            with mock.patch('workspace.subprocess.run', return_value=process):
                self.assertIsNone(workspace.native_host_key(vm))
                process.stdout = 'qemu -drive file=' + str(vm / 'disk.img') + ',format=raw'
                self.assertEqual(key, workspace.native_host_key(vm))

    def test_native_omarchy_uses_the_same_developer_connection_model(self):
        with tempfile.TemporaryDirectory() as directory:
            vm = Path(directory)
            (vm / 'guest-os').write_text('omarchy')
            (vm / 'vm.env').write_text("NAME='Omarchy'\nVM_USER=dev\nSSH_PORT=52222\n")
            session = workspace.Session(vm, '/home/dev/Developer')
            self.assertEqual('omarchy', session.guest)
            self.assertEqual('root@127.0.0.1', session.root_ssh()[-1])
            self.assertEqual('dev@127.0.0.1', session.ssh()[-1])
