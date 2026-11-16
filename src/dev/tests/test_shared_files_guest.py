import importlib.util
from pathlib import Path
import unittest
from unittest import mock

source = Path(__file__).resolve().parents[2] / 'ubuntu/guest/shared-files-client.py'
spec = importlib.util.spec_from_file_location('shared_guest', source)
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)


class SharedIdentityTests(unittest.TestCase):
    def test_null_kernel_identity_is_initialized_before_mounting(self):
        identifier = mock.Mock()
        identifier.exists.return_value = True
        identifier.read_text.return_value = '(null)\n'
        with mock.patch.object(guest, 'Path', return_value=identifier), mock.patch.object(guest, 'run') as run:
            guest.configure_identity({'client_id':'a'*64})
        run.assert_called_once_with('modprobe', 'nfsv4')
        identifier.write_text.assert_called_once_with('a'*64 + '\n')

    def test_missing_kernel_identity_support_never_silently_falls_back(self):
        identifier = mock.Mock()
        identifier.exists.return_value = False
        with mock.patch.object(guest, 'Path', return_value=identifier), mock.patch.object(guest, 'run'):
            with self.assertRaisesRegex(ValueError, 'kernel'): guest.configure_identity({'client_id':'b'*64})
        identifier.write_text.assert_not_called()


if __name__ == '__main__': unittest.main()
