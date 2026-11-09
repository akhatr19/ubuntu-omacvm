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


class LifecycleTests(unittest.TestCase):
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
