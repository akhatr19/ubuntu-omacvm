import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("seed", Path(__file__).parents[1] / "seed.py")
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class SeedTests(unittest.TestCase):
    def test_install_targets_only_the_vm_disk(self):
        data = seed.config("ubuntu", "ubuntu", "$6$hashed", "ssh-ed25519 AAAA test")
        install = data["autoinstall"]
        self.assertEqual(install["storage"]["layout"]["match"], {"serial": "QEMU_NVMe_Ctrl_omacvm_1"})
        self.assertFalse(install["ssh"]["allow-pw"])
        self.assertFalse(install["user-data"]["ssh_deletekeys"])
        self.assertEqual(install["shutdown"], "poweroff")

    def test_rejects_shell_injection_and_plain_passwords(self):
        for user, hostname, password, key in [
            ("a;id", "ubuntu", "$6$hash", "ssh-ed25519 AAAA"),
            ("ubuntu", "$(id)", "$6$hash", "ssh-ed25519 AAAA"),
            ("ubuntu", "ubuntu", "plain", "ssh-ed25519 AAAA"),
            ("ubuntu", "ubuntu", "$6$hash", "ssh-ed25519 AAAA\ncommand=bad"),
        ]:
            with self.subTest(user=user, hostname=hostname, password=password):
                with self.assertRaises(ValueError):
                    seed.config(user, hostname, password, key)


if __name__ == "__main__":
    unittest.main()
