import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from manifest import check_lock, load


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.path = self.root / 'uvm.json'
        self.data = {'schema': 1, 'name': 'example', 'base': {'path': '../base', 'sha256': 'a' * 64},
                     'snapshot': '20261108T000000Z'}

    def tearDown(self):
        self.temporary.cleanup()

    def read(self):
        self.path.write_text(json.dumps(self.data))
        return load(self.path)

    def test_portable_lock_and_profile_expansion(self):
        settings, lock, packages = self.read()
        lock.update(apt_requested=[], apt_inventory=[])
        self.assertIn('git', packages)
        self.assertEqual(lock['packages'], packages)
        self.data['base']['path'] = '/a/different/machine/base'
        check_lock(lock, self.read()[1])
        self.assertFalse(settings['ssh_agent'])
        self.assertEqual(settings['interop'], [])

    def test_changed_script_invalidates_lock(self):
        script = self.root / 'setup.sh'
        script.write_text('echo first\n')
        self.data['provision'] = ['setup.sh']
        lock = self.read()[1]
        script.write_text('echo second\n')
        with self.assertRaises(ValueError):
            check_lock(lock, self.read()[1])

    def test_scripts_cannot_escape_project(self):
        outside = self.root.parent / (self.root.name + '-outside')
        outside.write_text('echo outside')
        try:
            (self.root / 'linked.sh').symlink_to(outside)
            for name in ['../' + outside.name, str(outside), 'linked.sh', 'uvm.json']:
                self.data['provision'] = [name]
                with self.subTest(name=name), self.assertRaises(ValueError):
                    self.read()
        finally:
            outside.unlink()

    def test_invalid_inputs_rejected(self):
        for field, value in [('name', '../personal'), ('snapshot', 'latest'), ('profiles', ['missing']),
                             ('packages', ['--allow-unauthenticated']), ('resources', {'cpus': True, 'memory_gb': 8}),
                             ('ports', [{'host': 3000, 'guest': 3000}, {'host': 3000, 'guest': 4000}]),
                             ('interop', ['exec']), ('images', ['ubuntu:latest']), ('unexpected', True)]:
            with self.subTest(field=field):
                original = self.data.copy()
                self.data[field] = value
                with self.assertRaises(ValueError):
                    self.read()
                self.data = original

    def test_container_and_git_inputs_are_immutable(self):
        self.data.update(profiles=['docker'], images=['docker.io/library/hello-world@sha256:' + 'b' * 64],
                         git={'url': 'https://example.org/repo.git', 'commit': 'c' * 40})
        self.read()
        self.data['git']['commit'] = 'main'
        with self.assertRaises(ValueError):
            self.read()


if __name__ == '__main__':
    unittest.main()
