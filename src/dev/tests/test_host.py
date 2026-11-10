import base64
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import interop
from supervisor import listening_ports


class HostBoundaryTests(unittest.TestCase):
    def test_ports_cover_ipv4_and_ipv6_without_privileged_ports(self):
        output = 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*\nLISTEN 0 128 [::1]:8080 [::]:*\nLISTEN 0 128 *:22 *:*\n'
        self.assertEqual(listening_ports(output), {3000: '127.0.0.1', 8080: '[::1]'})

    @mock.patch('interop.subprocess.run')
    def test_no_capability_means_no_host_action(self, process):
        for action in ['open', 'copy', 'paste', 'export', 'exec']:
            with self.subTest(action=action), self.assertRaises(ValueError):
                interop.action({'id': 1, 'action': action}, [], Path('/unused'))
        process.assert_not_called()

    @mock.patch('interop.subprocess.run')
    def test_url_protocols_and_controls(self, process):
        for url in ['file:///etc/passwd', 'javascript:alert(1)', 'https://example.org/\nmore', 'https://']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                interop.action({'id': 1, 'action': 'open', 'url': url}, ['browser'], Path('/unused'))
        process.assert_not_called()
        interop.action({'id': 1, 'action': 'open', 'url': 'http://localhost:3000/'}, ['browser'], Path('/unused'))
        process.assert_called_once_with(['/usr/bin/open', 'http://localhost:3000/'], check=True)

    @mock.patch('interop.subprocess.run')
    def test_exports_never_overwrite_or_traverse(self, process):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)
            data = base64.b64encode(b'first').decode()
            request = {'id': 1, 'action': 'export', 'name': 'report.txt', 'data': data}
            self.assertEqual(interop.action(request, ['export'], target)['name'], 'report.txt')
            self.assertEqual(interop.action(request, ['export'], target)['name'], 'report (2).txt')
            self.assertEqual((target / 'report.txt').read_bytes(), b'first')
            for name in ['../escape', '/escape', '..', 'bad\nname', 'dir\\file']:
                with self.subTest(name=name), self.assertRaises(ValueError):
                    interop.action({**request, 'name': name}, ['export'], target)
        self.assertEqual(process.call_count, 2)

    @mock.patch('interop.subprocess.run')
    def test_invalid_payload_is_rejected(self, process):
        with self.assertRaises(ValueError):
            interop.action({'id': 1, 'action': 'copy', 'data': '$invalid'}, ['clipboard'], Path('/unused'))
        process.assert_not_called()


if __name__ == '__main__':
    unittest.main()
