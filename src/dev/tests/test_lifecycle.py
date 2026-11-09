import fcntl
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import supervisor


class LifecycleTests(unittest.TestCase):
    def test_ssh_readiness_waits_for_an_authenticated_master(self):
        process = mock.Mock()
        process.poll.return_value = None
        with mock.patch('supervisor.ssh_args', return_value=['ssh', 'root@127.0.0.1']) as args, \
             mock.patch('supervisor.subprocess.Popen', return_value=process), \
             mock.patch('supervisor.Path.unlink'), mock.patch('supervisor.time.sleep'), \
             mock.patch('supervisor.subprocess.run', side_effect=[mock.Mock(returncode=255), mock.Mock(returncode=0)]) as check:
            connected, _ = supervisor.connect_master(Path('/unused'), '/unused-control')
            self.assertIs(connected, process)
            self.assertEqual(check.call_count, 2)
            args.assert_called_once_with(Path('/unused'), root=True, allow_starting=True)

    def test_concurrent_cold_start_waits_for_the_existing_supervisor(self):
        ready = {'qemu_pid': 123, 'ready': True, 'mode': 'headless'}
        with mock.patch('runtime.live', side_effect=[{'qemu_pid': 123, 'ready': False}, ready]), \
             mock.patch('runtime.subprocess.Popen') as spawn, mock.patch('runtime.disk_busy') as busy:
            self.assertEqual(runtime.ensure_up(Path('/unused')), ready)
            spawn.assert_not_called()
            busy.assert_not_called()

    def test_stop_waits_for_supervisor_before_desktop_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with open(root / 'owner.lock', 'a') as owner:
                fcntl.flock(owner, fcntl.LOCK_EX)
                release = threading.Timer(.15, lambda: fcntl.flock(owner, fcntl.LOCK_UN))
                release.start()
                try:
                    with mock.patch('runtime.sockets', return_value=root), \
                         mock.patch('runtime.live', side_effect=[{'qemu_pid': 123}, None, None]), \
                         mock.patch('runtime.socket_request'):
                        started = time.monotonic()
                        runtime.stop(root)
                        self.assertGreaterEqual(time.monotonic() - started, .12)
                finally:
                    release.join()


if __name__ == '__main__':
    unittest.main()
