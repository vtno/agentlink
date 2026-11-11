"""Unpack an archive, check both help paths, and start and stop a plane."""

import argparse
import os
from pathlib import Path
import signal
import socket
import subprocess
import tarfile
import tempfile
import zipfile


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def command(binary, *args):
    if os.name == "nt":
        return _windows_command(os.environ["COMSPEC"], binary, args)
    return [str(binary), *args]


def _windows_command(comspec, binary, args):
    # cmd /s /c requires an outer quote pair around a quoted batch path.
    return (subprocess.list2cmdline([comspec]) + ' /d /s /c "' +
            subprocess.list2cmdline([str(binary), *args]) + '"')


def unix_identity(pid):
    stat = Path(f"/proc/{pid}/stat")
    if stat.exists():
        started = stat.read_text().rsplit(") ", 1)[1].split()[19]
    else:
        started = subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart="], text=True).strip()
        if not started:
            raise RuntimeError("Plane exited before its creation time was read")
    return pid, started


class WindowsProcess:
    """Keep a process handle and creation time so PID reuse cannot change the target."""

    def __init__(self, pid):
        import ctypes
        from ctypes import wintypes

        self.ctypes = ctypes
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenProcess.restype = wintypes.HANDLE
        self.api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.api.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        self.api.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        self.api.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.api.OpenProcess(0x100000 | 0x1000 | 1, False, pid)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        times = [wintypes.FILETIME() for _ in range(4)]
        if not self.api.GetProcessTimes(self.handle, *(ctypes.byref(t) for t in times)):
            raise ctypes.WinError(ctypes.get_last_error())
        self.identity = (pid, times[0].dwHighDateTime << 32 | times[0].dwLowDateTime)

    def wait(self):
        from ctypes import wintypes

        if self.api.WaitForSingleObject(self.handle, 0xFFFFFFFF) != 0:
            raise self.ctypes.WinError(self.ctypes.get_last_error())
        code = wintypes.DWORD()
        if not self.api.GetExitCodeProcess(self.handle, self.ctypes.byref(code)):
            raise self.ctypes.WinError(self.ctypes.get_last_error())
        if code.value != 0:
            raise RuntimeError(f"Plane {self.identity} exited with {code.value}")

    def close(self):
        if self.api.WaitForSingleObject(self.handle, 0) == 0x102:
            self.api.TerminateProcess(self.handle, 1)
            self.api.WaitForSingleObject(self.handle, 0xFFFFFFFF)
        self.api.CloseHandle(self.handle)


def smoke(release, home):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("RELEASE_", "ERL_", "ELIXIR_", "AGENTLINK_"))
           and key not in {"ROOTDIR", "BINDIR", "PROGNAME"}}
    installs = [os.environ.get(key, "").casefold()
                for key in ["INSTALL_DIR_FOR_OTP", "INSTALL_DIR_FOR_ELIXIR"]]
    env["PATH"] = os.pathsep.join(p for p in env["PATH"].split(os.pathsep)
                                 if not any(root and p.casefold().startswith(root) for root in installs))
    env.update(HOME=str(home), USERPROFILE=str(home), RELEASE_DISTRIBUTION="none")
    binary = release / "bin" / ("agentlink.bat" if os.name == "nt" else "agentlink")
    for args in [("--help",), ("start", "--help")]:
        result = subprocess.run(command(binary, *args), env=env, capture_output=True, text=True)
        if result.returncode != 0 or "agentlink plane" not in result.stdout:
            raise RuntimeError(f"Help failed: {result.returncode}\n{result.stdout}\n{result.stderr}")

    port = free_port()
    epmd = None
    process = None
    beam = None
    tracked = []
    identity = None
    try:
        if os.name == "nt":
            epmd_port = free_port()
            while epmd_port == port:
                epmd_port = free_port()
            runtime, _version = (release / "releases/start_erl.data").read_text().split()
            epmd_bin = release / f"erts-{runtime}/bin/epmd.exe"
            # Own a foreground epmd on a private port instead of leaving a daemon.
            epmd = subprocess.Popen([str(epmd_bin), "-port", str(epmd_port)], env=env)
            tracked.append(WindowsProcess(epmd.pid))
            while True:
                if epmd.poll() is not None:
                    raise RuntimeError("epmd exited before listening")
                try:
                    with socket.create_connection(("127.0.0.1", epmd_port)):
                        break
                except ConnectionRefusedError:
                    continue
            env.update(RELEASE_DISTRIBUTION="sname", RELEASE_NODE=f"agentlink_smoke_{os.getpid()}",
                       RELEASE_COOKIE="ci-smoke", ERL_EPMD_PORT=str(epmd_port),
                       ELIXIR_ERL_OPTIONS="-start_epmd false")

        process = subprocess.Popen(
            command(binary, "plane", "--port", str(port), "--token", "ci-smoke"),
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            start_new_session=os.name != "nt",
        )
        if os.name == "nt":
            tracked.append(WindowsProcess(process.pid))
        else:
            identity = unix_identity(process.pid)
        for line in process.stdout:
            print(line.replace("ci-smoke", "[test-token]"), end="", flush=True)
            if "Running AgentLink.Router with Bandit" in line and f"127.0.0.1:{port}" in line:
                break
        else:
            raise RuntimeError("Plane exited before its listener started")

        if os.name == "nt":
            result = subprocess.run(command(binary, "pid"), env=env, capture_output=True,
                                    text=True, check=True)
            beam = WindowsProcess(int(result.stdout.strip()))
            tracked.append(beam)
            subprocess.run(command(binary, "stop"), env=env, check=True)
            beam.wait()
        else:
            # A live, unreaped Popen child cannot have its PID reused.
            if process.poll() is not None:
                raise RuntimeError("Plane exited before SIGTERM")
            if unix_identity(process.pid) != identity:
                raise RuntimeError("Plane process identity changed")
            os.killpg(process.pid, signal.SIGTERM)
        if process.wait() != 0:
            raise RuntimeError("Plane launcher did not exit cleanly")
        if os.name != "nt":
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise RuntimeError("Plane process group still exists")
        if epmd is not None:
            while True:
                names = subprocess.run([str(epmd_bin), "-port", str(epmd_port), "-names"],
                                       env=env, capture_output=True, text=True, check=True)
                if not any(line.startswith("name ") for line in names.stdout.splitlines()):
                    break
            subprocess.run([str(epmd_bin), "-port", str(epmd_port), "-kill"], env=env, check=True)
            if epmd.wait() != 0:
                raise RuntimeError("epmd did not exit cleanly")
    finally:
        for owned in reversed(tracked):
            owned.close()
        if process is not None and process.poll() is None:
            if os.name == "nt":
                process.kill()
            else:
                if unix_identity(process.pid) != identity:
                    raise RuntimeError("Plane process identity changed during cleanup")
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        if epmd is not None and epmd.poll() is None:
            epmd.kill()
            epmd.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive_directory", type=Path)
    args = parser.parse_args()
    [archive] = list(args.archive_directory.iterdir())
    with tempfile.TemporaryDirectory(prefix="agentlink smoke ") as tmp:
        root = Path(tmp)
        release = root / "release"
        release.mkdir()
        if archive.suffix == ".zip":
            with zipfile.ZipFile(archive) as handle:
                handle.extractall(release)
        else:
            with tarfile.open(archive) as handle:
                handle.extractall(release, filter="data")
        home = root / "home"
        home.mkdir()
        smoke(release, home)


if __name__ == "__main__":
    main()
