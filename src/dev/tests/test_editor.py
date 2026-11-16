from pathlib import Path
import argparse
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import integrate
import workspace


class EditorTests(unittest.TestCase):
    def app(self, root, name):
        app = root / name
        executable = app / 'Contents/Resources/app/bin/code'
        executable.parent.mkdir(parents=True)
        executable.write_text('#!/bin/sh\nexit 0\n'); executable.chmod(0o700)
        return app, executable

    def test_auto_detects_insiders_with_a_command_named_code(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); app, executable = self.app(root, 'Visual Studio Code - Insiders.app')
            with mock.patch.dict(os.environ, {'UVM_CODE':''}), mock.patch.object(integrate, 'HOME', root), mock.patch.object(integrate, 'EDITOR_FOLDERS', (root,)), mock.patch.object(integrate, 'run') as run:
                integrate.open_editor('uvm-dev', '/home/u/A project')
                self.assertEqual(run.call_args.args[0], [str(executable), '--folder-uri', 'vscode-remote://ssh-remote+uvm-dev/home/u/A%20project'])

    def test_selected_application_wins_and_missing_choice_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); app, executable = self.app(root, 'My Insiders.app')
            (root/'editor.json').write_text(json.dumps({'schema':1, 'application':str(app)}))
            with mock.patch.dict(os.environ, {'UVM_CODE':''}), mock.patch.object(integrate, 'HOME', root):
                self.assertEqual(integrate.editor_executable(), str(executable))
                executable.unlink()
                with self.assertRaisesRegex(ValueError, 'unavailable'): integrate.editor_executable()

    def test_editor_failure_does_not_start_managed_or_desktop_vm(self):
        with mock.patch.object(integrate, 'editor_executable', side_effect=ValueError('missing editor')), mock.patch.object(integrate, 'ensure_up') as boot:
            with self.assertRaises(ValueError): integrate.editor(Path('/unused'))
            boot.assert_not_called()
        args = argparse.Namespace(vm=Path('/unused'), project='/home/u/project', qga='/unused', action='code')
        with mock.patch.object(workspace, 'Session') as session, mock.patch.object(integrate, 'editor_executable', side_effect=ValueError('missing editor')):
            with self.assertRaises(ValueError): workspace.main(args)
            session.return_value.ensure.assert_not_called()

    def test_explicit_command_override_is_preserved(self):
        with mock.patch.dict(os.environ, {'UVM_CODE':'custom-code'}), mock.patch.object(integrate.shutil, 'which', return_value='/custom/code'):
            self.assertEqual(integrate.editor_executable(), '/custom/code')


if __name__ == '__main__': unittest.main()
