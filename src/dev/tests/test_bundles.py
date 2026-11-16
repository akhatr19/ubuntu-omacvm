import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bundles
from manifest import digest, write_json


class BundleTests(unittest.TestCase):
    @mock.patch('bundles.runtime_identity', return_value='a' * 64)
    def test_disk_tampering_and_runtime_changes_are_rejected(self, identity):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with open(root / 'disk.img', 'wb') as disk:
                disk.truncate(1024 ** 3)
            (root / 'efi-vars.fd').write_bytes(b'firmware variables')
            data = {'schema': 1, 'kind': 'base', 'user': 'ubuntu', 'disk_gb': 1,
                    'runtime_commit': bundles.RUNTIME_COMMIT, 'runtime_sha256': 'a' * 64,
                    'files': {name: digest(root / name) for name in bundles.FILES}}
            write_json(root / 'bundle.json', data)
            bundles.describe(root)
            (root / 'efi-vars.fd').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                bundles.describe(root)
            identity.return_value = 'b' * 64
            with self.assertRaisesRegex(ValueError, 'runtime'):
                bundles.describe(root)

    def test_imported_scripts_cannot_escape_or_change_locked_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            manifest = {'schema': 1, 'name': 'example', 'base': {'path': '../base', 'sha256': 'a' * 64},
                        'snapshot': '20261108T000000Z', 'provision': []}
            for name in ('../escape', '/escape', 'uvm.json', 'dir/../../escape'):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    bundles.restore_definition(root, {'manifest': manifest, 'scripts': {name: 'ZWNobw=='}})
            with self.assertRaisesRegex(ValueError, 'match'):
                bundles.restore_definition(root, {'manifest': manifest, 'scripts': {'extra.sh': 'ZWNobw=='}})


if __name__ == '__main__':
    unittest.main()
