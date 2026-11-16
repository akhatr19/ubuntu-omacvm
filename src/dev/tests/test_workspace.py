import argparse
import json
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import workspace


class WorkspaceTests(unittest.TestCase):
    def test_linux_paths_reject_traversal_controls_and_root(self):
        for value in ('/', '../project', '/home/u/../other', '/home/u/\nproject', '/home/u/\x00'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                workspace.project_path(value)
        self.assertEqual(workspace.project_path('/home/u/My Project/'), '/home/u/My Project')

    def test_desktop_metadata_is_parsed_without_executing_shell(self):
        with tempfile.TemporaryDirectory() as folder:
            vm = Path(folder) / 'OmacVM Test-desktop'
            vm.mkdir(); (vm / 'guest-os').write_text('ubuntu')
            (vm / 'vm.env').write_text("NAME='My Ubuntu'\nVM_USER=ubuntu\nSSH_PORT=52222\nOTHER=$(touch /never-run)\n")
            session = workspace.Session(vm, '/home/ubuntu/project with spaces')
            self.assertEqual(session.metadata['vm_name'], 'My Ubuntu')
            self.assertEqual(session.metadata['user'], 'ubuntu')
            self.assertIn('StrictHostKeyChecking=yes', session.ssh())
            self.assertIn('BatchMode=yes', session.ssh())

    def test_remote_argv_is_quoted_not_interpreted_locally(self):
        session = object.__new__(workspace.Session)
        session.ssh = lambda: ['ssh', 'test-vm']
        argv = ['git', 'clone', '--', 'https://example.org/$(bad);repo', '/home/u/My Project']
        with mock.patch('workspace.subprocess.run') as run:
            session.run(argv)
            self.assertEqual(shlex.split(run.call_args.args[0][-1]), argv)
            self.assertNotIn('shell', run.call_args.kwargs)

    def test_export_never_overwrites_and_does_not_extract_guest_files(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'existing.tar.gz'; target.write_bytes(b'keep')
            args = argparse.Namespace(vm=Path(folder), project='/home/u/project', qga=None, action='export', source=str(target))
            with mock.patch('workspace.Session') as session, self.assertRaises(ValueError):
                workspace.main(args)
            self.assertEqual(target.read_bytes(), b'keep')
            session.return_value.run.assert_not_called()

    def test_export_race_does_not_remove_another_file(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'race.tar.gz'; target.write_bytes(b'keep')
            args = argparse.Namespace(vm=Path(folder), project='/home/u/project', qga=None, action='export', source=str(target))
            with mock.patch('workspace.Session'), mock.patch.object(Path, 'exists', return_value=False), self.assertRaises(FileExistsError):
                workspace.main(args)
            self.assertEqual(target.read_bytes(), b'keep')

    def test_container_requires_configuration_and_docker(self):
        session = object.__new__(workspace.Session)
        session.project = '/home/u/project'
        session.info = lambda: {'exists': True, 'devcontainer': False}
        with self.assertRaisesRegex(ValueError, 'devcontainer'):
            session.editor(container=True)

    def test_missing_git_does_not_change_a_locked_environment(self):
        session = object.__new__(workspace.Session)
        session.managed = True
        session.run = mock.Mock(return_value=mock.Mock(stdout='False\n'))
        with mock.patch('workspace.rt.socket_request') as agent, self.assertRaisesRegex(ValueError, 'provision'):
            session.ensure_git()
        agent.assert_not_called()

    def test_existing_git_never_runs_package_installation(self):
        session = object.__new__(workspace.Session)
        session.run = mock.Mock(return_value=mock.Mock(stdout='True\n'))
        with mock.patch('workspace.rt.socket_request') as agent:
            session.ensure_git()
        agent.assert_not_called()

    def test_test_mode_cannot_open_personal_vm(self):
        with mock.patch.dict('os.environ', {'UVM_TEST_MODE': '1'}), self.assertRaisesRegex(ValueError, 'personal VM'):
            workspace.Session('/some/Ubuntu', '/home/u/project')


if __name__ == '__main__':
    unittest.main()
