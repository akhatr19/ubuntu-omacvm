import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import homefolders as host

spec = importlib.util.spec_from_file_location('home_guest', Path(__file__).resolve().parents[2] / 'ubuntu/guest/home-folders.py')
guest = importlib.util.module_from_spec(spec)
with mock.patch.object(os, 'O_PATH', 0, create=True): spec.loader.exec_module(guest)


class HomeFoldersTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.vm = self.home / 'OmacVM Test-home'
        self.vm.mkdir()
        self.patch = mock.patch.object(host.rt, 'HOME', self.home / 'settings')
        self.patch.start(); self.addCleanup(self.patch.stop)
        self.env = mock.patch.dict(os.environ, {'UVM_TEST_MODE': '1'})
        self.env.start(); self.addCleanup(self.env.stop)

    def test_default_exports_only_selected_folders(self):
        args = host.arguments(self.vm)
        self.assertEqual(3, args.count('-fsdev'))
        self.assertEqual(['Desktop', 'Documents', 'Downloads'], host.settings())
        self.assertTrue(all((host.root() / name).is_dir() for name in host.DEFAULTS))
        self.assertNotIn('.config', ' '.join(args))
        self.assertNotIn(str(Path.home() / 'Documents'), ' '.join(args))

    def test_off_and_legacy_disk_expose_no_mac_folders(self):
        for marker in (host.OFF, 'file-service', 'data-volume.json'):
            (self.vm / marker).touch()
            self.assertEqual([], host.arguments(self.vm))
            (self.vm / marker).unlink()
        self.assertFalse(host.root().exists())

    def test_links_cannot_export_another_folder(self):
        host.root().mkdir(parents=True)
        (host.root() / 'Desktop').symlink_to(self.vm)
        with self.assertRaisesRegex(ValueError, 'symbolic'): host.arguments(self.vm)

    def test_custom_folder_and_rejections(self):
        host.rt.HOME.mkdir()
        (host.rt.HOME / 'home-folders.json').write_text(json.dumps({'schema':1, 'folders':['Developer']}))
        args = host.arguments(self.vm)
        self.assertEqual(1, args.count('-fsdev'))
        self.assertIn(str(host.root() / 'Developer'), ' '.join(args))
        for names in (['.config'], ['../Desktop'], ['a/b'], ['Docs', 'docs'], ['UbuntuVM Local Folders'], ['Mac'], ['x'] * 17):
            with self.assertRaises(ValueError): host.names(names)

    def test_guest_parses_real_smbios_header_and_validates_grants(self):
        value = base64.b64encode(b'Developer')
        self.assertEqual({'Developer':0}, guest.selections(b'\x0b\x05\x01uvm.home=0:' + value + b'\0\0'))
        self.assertEqual({}, guest.selections(b'other OEM values\0'))
        for raw in (b'uvm.home=17:' + value, b'uvm.home=0:Li5c', b'uvm.home=0:' + value + b'\0uvm.home=1:' + value):
            with self.assertRaises(ValueError): guest.selections(raw)


if __name__ == '__main__': unittest.main()
