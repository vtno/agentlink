import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

from package_release import inventory, package, swap_runtime
from smoke_release import _windows_command


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.base = root / "base"
        self.otp = root / "otp"
        self.output = root / "dist"
        self.write(self.base, "releases/start_erl.data", "17.1 0.1.0")
        self.write(self.base, "erts-17.1/bin/erl", "relocatable erl")
        self.write(self.base, "erts-17.1/bin/linux-only", "old binary")
        self.write(self.base, "lib/kernel-1/ebin/kernel.beam", "old OTP beam")
        self.write(self.base, "lib/kernel-1/priv/linux.so", "old native code")
        self.write(self.base, "lib/agent_link-1/ebin/agent.beam", "compiled once")
        self.write(self.base, "bin/agentlink.bat", "patched batch launcher")
        self.write(self.otp, "erts-17.1/bin/erl.exe", "target binary")
        self.write(self.otp, "erts-17.1/bin/erl.ini", "non-relocatable install root")
        self.write(self.otp, "lib/kernel-1/ebin/kernel.beam", "target OTP beam")
        self.write(self.otp, "lib/kernel-1/priv/target.dll", "target native code")
        inventory(self.base, self.otp)

    @staticmethod
    def write(root, name, text):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_swaps_runtime_and_otp_without_recompiling_project(self):
        swap_runtime(self.base, self.otp)
        self.assertEqual((self.base / "erts-17.1/bin/erl").read_text(), "relocatable erl")
        self.assertFalse((self.base / "erts-17.1/bin/linux-only").exists())
        self.assertFalse((self.base / "erts-17.1/bin/erl.ini").exists())
        self.assertEqual((self.base / "erts-17.1/bin/erl.exe").read_text(), "target binary")
        self.assertFalse((self.base / "lib/kernel-1/priv/linux.so").exists())
        self.assertTrue((self.base / "lib/kernel-1/priv/target.dll").is_file())
        self.assertEqual((self.base / "lib/kernel-1/ebin/kernel.beam").read_text(), "target OTP beam")
        self.assertEqual((self.base / "lib/agent_link-1/ebin/agent.beam").read_text(), "compiled once")
        self.assertEqual((self.base / "bin/agentlink.bat").read_text(), "patched batch launcher")

    def test_rejects_different_erts_or_application_versions_before_modifying_release(self):
        for field, value in [("erts", "wrong"), ("apps", ["kernel-wrong"])]:
            metadata = json.loads((self.base / "runtime.json").read_text())
            metadata[field] = value
            (self.base / "runtime.json").write_text(json.dumps(metadata))
            with self.assertRaises(ValueError):
                swap_runtime(self.base, self.otp)
            self.assertTrue((self.base / "erts-17.1/bin/linux-only").exists())
            inventory(self.base, self.otp)

    def test_both_archives_contain_swapped_files_and_leave_base_unchanged(self):
        for target in ["linux-x86_64", "windows-x86_64"]:
            archive = package(self.base, self.otp, target, self.output)
            if target.startswith("windows-"):
                with zipfile.ZipFile(archive) as handle:
                    files = handle.namelist()
            else:
                with tarfile.open(archive) as handle:
                    files = [name.removeprefix("./") for name in handle.getnames()]
            self.assertIn("erts-17.1/bin/erl.exe", files)
            self.assertIn("lib/agent_link-1/ebin/agent.beam", files)
            self.assertNotIn("erts-17.1/bin/erl.ini", files)
        self.assertTrue((self.base / "erts-17.1/bin/linux-only").exists())

    def test_windows_smoke_quotes_a_batch_path_containing_spaces(self):
        command = _windows_command(r"C:\Windows\System32\cmd.exe",
                                   r"C:\agentlink smoke\release\bin\agentlink.bat",
                                   ("start", "--help"))
        self.assertEqual(command,
                         r'C:\Windows\System32\cmd.exe /d /s /c ""C:\agentlink smoke\release\bin\agentlink.bat" start --help"')


if __name__ == "__main__":
    unittest.main()
