from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import files


class FilesTests(unittest.TestCase):
    def test_password_is_stdin_not_command_arguments_or_state(self):
        with tempfile.TemporaryDirectory() as directory:
            session = mock.Mock(vm=Path(directory), metadata={'user':'ubuntu'})
            with mock.patch('files.agent') as agent, mock.patch('files.free_port', return_value=55222):
                result = files.setup(session, 'fixture-only-password')
            self.assertEqual(result['port'], 55222)
            command = agent.call_args.args[1]
            self.assertNotIn('fixture-only-password', command)
            self.assertEqual(agent.call_args.args[2], b'fixture-only-password\n')
            self.assertNotIn('password', (Path(directory)/'finder-drive.json').read_text())

    def test_password_change_keeps_the_finder_endpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder/'finder-drive.json').write_text('{"port":55223}')
            session = mock.Mock(vm=folder, metadata={'user':'ubuntu'})
            with mock.patch('files.agent'), mock.patch('files.free_port') as allocate:
                result = files.setup(session, 'fixture-only-password')
            self.assertEqual(result['port'], 55223)
            allocate.assert_not_called()

    def test_sync_dry_run_has_no_delete_and_quotes_linux_path(self):
        session = mock.Mock(project='/home/u/A project', metadata={'user':'u'})
        session.ssh.return_value=['ssh', '-i', '/some key', 'u@127.0.0.1']
        with tempfile.TemporaryDirectory() as directory, mock.patch('files.subprocess.run') as run:
            files.sync(session, Path(directory), 'to-linux', True)
        command = run.call_args.args[0]
        self.assertIn('--dry-run', command)
        self.assertIn('--backup', command)
        self.assertIn('--checksum', command)
        self.assertNotIn('--delete', command)
        self.assertEqual(command[-1], "u@127.0.0.1:'/home/u/A project/'")
        session.run.assert_called_once()  # version check only; preview makes no directories

    def test_sync_rejects_entire_mac_home(self):
        with self.assertRaisesRegex(ValueError, 'home'):
            files.sync(mock.Mock(), Path.home(), 'to-linux', True)

    def test_smb_root_is_readonly_and_loopback_only(self):
        source=(Path(__file__).resolve().parents[2]/'ubuntu/guest/file-sharing.sh').read_text()
        self.assertIn('interfaces = lo', source)
        self.assertIn('bind interfaces only = yes', source)
        self.assertIn('map to guest = Never', source)
        root=source.split('[Root]')[1].split('[Home]')[0]
        self.assertIn('force user = root', root)
        self.assertIn('read only = yes', root)


if __name__ == '__main__': unittest.main()
