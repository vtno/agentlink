import json
from pathlib import Path
import tarfile
import tempfile
import threading
import unittest
import zipfile

from package_release import inventory, package, swap_runtime
from smoke_release import (
    _children_from_ps_text,
    _children_from_task_dir,
    _identity_from_ps,
    _identity_from_stat,
    _windows_command,
    consume_stdout,
)


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
            self.assertNotIn("runtime.json", files)
            self.assertFalse(any(name.endswith("/runtime.json") for name in files))
        self.assertTrue((self.base / "erts-17.1/bin/linux-only").exists())
        self.assertTrue((self.base / "runtime.json").is_file())

    def test_windows_smoke_quotes_a_batch_path_containing_spaces(self):
        command = _windows_command(r"C:\Windows\System32\cmd.exe",
                                   r"C:\agentlink smoke\release\bin\agentlink.bat",
                                   ("start", "--help"))
        self.assertEqual(command,
                         r'C:\Windows\System32\cmd.exe /d /s /c ""C:\agentlink smoke\release\bin\agentlink.bat" start --help"')


class SmokeHelperTest(unittest.TestCase):
    def test_proc_children_lists_only_that_task_directory(self):
        root = Path(self._tmpdir())
        task = root / "99" / "task"
        self.write_children(task / "1", "10 11\n")
        self.write_children(task / "2", "11 12")
        self.assertEqual(_children_from_task_dir(task), [10, 11, 12])

    def test_ps_children_keep_only_the_parent_pid(self):
        text = "\n".join([
            "  1  0",
            "  20  7",
            "  21  8",
            "  22  7",
            "  7  1",
        ])
        self.assertEqual(_children_from_ps_text(text, 7), [20, 22])

    def test_ps_identity_is_none_when_ps_exits_or_prints_nothing(self):
        class Ps:
            def __init__(self, returncode, stdout):
                self.returncode = returncode
                self.stdout = stdout

            def __call__(self, args, capture_output, text, check):
                self.args = args
                self.capture_output = capture_output
                self.text = text
                self.check = check
                return self

        exited = Ps(1, "")
        self.assertIsNone(_identity_from_ps(41, exited))
        self.assertEqual(exited.args, ["ps", "-p", "41", "-o", "lstart="])
        self.assertTrue(exited.capture_output)
        self.assertTrue(exited.text)
        self.assertFalse(exited.check)
        self.assertIsNone(_identity_from_ps(41, Ps(0, " \n")))
        present = Ps(0, "Wed Nov 11 20:15:07 2026\n")
        self.assertEqual(_identity_from_ps(41, present), (41, "Wed Nov 11 20:15:07 2026"))

    def test_proc_identity_is_none_when_stat_disappears(self):
        class Missing:
            def exists(self):
                return False

            def read_text(self):
                raise AssertionError("read_text")

        class Removed:
            def exists(self):
                return True

            def read_text(self):
                raise FileNotFoundError("stat")

        class Present:
            def exists(self):
                return True

            def read_text(self):
                return "41 (erl_child_setup) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0 12345\n"

        self.assertIsNone(_identity_from_stat(41, Missing()))
        self.assertIsNone(_identity_from_stat(41, Removed()))
        self.assertEqual(_identity_from_stat(41, Present()), (41, "12345"))

    def test_stdout_reader_keeps_reading_after_the_listener_line(self):
        lines = [
            "Running AgentLink.Router with Bandit 127.0.0.1:9\n",
            "shutdown-log\n",
        ]
        pending = iter(lines)
        seen = []

        class Stream:
            def __iter__(self):
                return self

            def __next__(self):
                line = next(pending)
                seen.append(line)
                return line

        found = threading.Event()
        wake = threading.Event()
        reader = threading.Thread(target=consume_stdout, args=(Stream(), 9, found, wake))
        reader.start()
        self.addCleanup(reader.join)
        wake.wait()
        self.assertTrue(found.is_set())
        reader.join()
        self.assertEqual(seen, lines)

    def _tmpdir(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return tmp.name

    @staticmethod
    def write_children(directory, text):
        directory.mkdir(parents=True)
        (directory / "children").write_text(text)


if __name__ == "__main__":
    unittest.main()
