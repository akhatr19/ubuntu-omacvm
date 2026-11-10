import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import integrate
import runtime


class SSHTests(unittest.TestCase):
    def test_known_hosts_path_with_spaces_is_one_ssh_config_value(self):
        vm = Path('/a VM/with spaces')
        with mock.patch('runtime.live', return_value={'ready': True, 'ssh_port': 2222}), \
             mock.patch('runtime.config', return_value={'user': 'ubuntu'}):
            args = runtime.ssh_args(vm)
        self.assertIn('UserKnownHostsFile="/a VM/with spaces/known_hosts"', args)
        self.assertIn('StrictHostKeyChecking=yes', args)

    def test_install_preserves_config_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / 'config'
            original = 'Host existing\n  HostName example.org\n'
            target.write_text(original)
            metadata = {'name': 'example', 'user': 'ubuntu', 'ssh_port': 2222, 'manifest': {'ssh_agent': False}}
            with mock.patch.dict(os.environ, {'UVM_SSH_CONFIG': str(target)}), \
                 mock.patch('integrate.HOME', root), mock.patch('integrate.app_bundle', return_value=Path('/Pinned app')), \
                 mock.patch('integrate.config', return_value=metadata):
                integrate.ssh_config(root / 'VM with spaces', True)
                first = target.read_text()
                integrate.ssh_config(root / 'VM with spaces', True)
            self.assertEqual(target.read_text(), first)
            self.assertTrue(first.endswith(original))
            self.assertEqual(first.count('Include '), 1)
            self.assertIn('ForwardAgent no', (root / 'ssh/example.conf').read_text())
            self.assertIn('UVM_VMS_ROOT=', (root / 'ssh/example.conf').read_text())


if __name__ == '__main__':
    unittest.main()
