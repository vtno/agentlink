"""Package a shared Mix release with a target's prebuilt OTP runtime."""

import argparse
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import zipfile


def inventory(release, otp):
    erts, _version = (release / "releases/start_erl.data").read_text().split()
    apps = sorted(p.name for p in (release / "lib").iterdir() if (otp / "lib" / p.name).is_dir())
    if not any(app.startswith("kernel-") for app in apps):
        raise ValueError("OTP root does not contain the release's kernel application")
    (release / "runtime.json").write_text(json.dumps({"erts": erts, "apps": apps}) + "\n")


def swap_runtime(release, otp):
    metadata = json.loads((release / "runtime.json").read_text())
    runtime = "erts-" + metadata["erts"]
    source = otp / runtime / "bin"
    if not source.is_dir():
        raise ValueError(f"Target OTP does not contain {runtime}")
    for app in metadata["apps"]:
        if not (otp / "lib" / app / "ebin").is_dir():
            raise ValueError(f"Target OTP application version differs: {app}")

    # Mix.Release.copy_erts rewrites erl for relocation and removes erl.ini.
    erl = (release / runtime / "bin/erl").read_bytes()
    shutil.rmtree(release / runtime)
    shutil.copytree(source, release / runtime / "bin")
    (release / runtime / "bin/erl.ini").unlink(missing_ok=True)
    (release / runtime / "bin/erl").write_bytes(erl)
    (release / runtime / "bin/erl").chmod(0o755)
    # OTP itself has native files and OS-specific code. Project and dependency
    # BEAM files remain those compiled by the single Linux Mix release build.
    for app in metadata["apps"]:
        destination = release / "lib" / app
        shutil.rmtree(destination)
        destination.mkdir()
        for directory in ["ebin", "priv", "include"]:
            source = otp / "lib" / app / directory
            if source.is_dir():
                shutil.copytree(source, destination / directory)


def package(base, otp, target, output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        release = Path(tmp) / "agentlink"
        shutil.copytree(base, release)
        swap_runtime(release, otp)
        if target.startswith("windows-"):
            archive = output / f"agentlink-{target}.zip"
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, strict_timestamps=False) as handle:
                for path in sorted(release.rglob("*")):
                    if path.is_file():
                        handle.write(path, path.relative_to(release))
        else:
            archive = output / f"agentlink-{target}.tar.gz"
            with tarfile.open(archive, "w:gz") as handle:
                handle.add(release, arcname=".")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser("inventory")
    record.add_argument("release", type=Path)
    record.add_argument("otp", type=Path)
    pack = commands.add_parser("package")
    pack.add_argument("release", type=Path)
    pack.add_argument("otp", type=Path)
    pack.add_argument("target")
    pack.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "inventory":
        inventory(args.release, args.otp)
    else:
        print(package(args.release, args.otp, args.target, args.output))


if __name__ == "__main__":
    main()
