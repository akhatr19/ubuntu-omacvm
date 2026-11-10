import base64
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import network

KEY = 'ssh-ed25519 ' + base64.b64encode(struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes(range(32))).decode() + ' test'


class NetworkTests(unittest.TestCase):
    def test_guest_key_configuration_refuses_macos(self):
        with mock.patch('network.sys.platform', 'darwin'), self.assertRaisesRegex(ValueError, 'Ubuntu guest'):
            network.apply_keys('ubuntu', '')

    def test_defaults_do_not_publish_to_the_lan(self):
        with tempfile.TemporaryDirectory() as folder:
            data = network.load(folder, {'auto_ports': True, 'ports': [{'host': 3000, 'guest': 3000}]})
            self.assertFalse(data['ssh_lan'])
            self.assertFalse(data['ports'][0]['lan'])
            self.assertTrue(data['auto_ports'])

    def test_local_overrides_can_disable_idle_and_scope_each_port(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'developer-network.json'
            path.write_text(json.dumps({'schema': 1, 'ssh_lan': True, 'ssh_port': 2223, 'idle_minutes': None,
                                        'public_keys': KEY, 'ports': [{'host': 8080, 'guest': 80, 'lan': True}]}))
            data = network.load(folder, {'idle_minutes': 30})
            self.assertIsNone(data['idle_minutes'])
            self.assertTrue(data['ports'][0]['lan'])
            self.assertEqual(network.public_keys(data['public_keys']), [KEY])

    def test_bad_ports_duplicate_ports_and_wrong_types_are_rejected(self):
        for ports in [[{'host': 22, 'guest': 80, 'lan': True}], [{'host': 8080, 'guest': 22, 'lan': True}],
                      [{'host': 8080, 'guest': 80, 'lan': False}] * 2, [{'host': True, 'guest': 80, 'lan': False}]]:
            with tempfile.TemporaryDirectory() as folder:
                (Path(folder) / 'developer-network.json').write_text(json.dumps({'ports': ports}))
                with self.assertRaises(ValueError): network.load(folder)

    def test_no_private_keys_options_or_forged_key_types(self):
        for value in ['-----BEGIN OPENSSH PRIVATE KEY-----', 'command="id" ' + KEY, 'ssh-rsa ' + KEY.split()[1], 'ssh-ed25519 AAAA']:
            with self.subTest(value=value), self.assertRaises(ValueError): network.public_keys(value)
        self.assertEqual(network.public_keys(' # comment\n\t\n' + KEY), [KEY])


if __name__ == '__main__': unittest.main()
