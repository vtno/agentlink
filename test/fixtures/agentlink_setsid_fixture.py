#!/usr/bin/env python3
"""A grandchild that has called setsid and ignores SIGTERM.

Prints ``ready <parent-pid> <grandchild-pid>`` and then all three processes
block in ``signal.pause``. The parent stays in the port's session. The
grandchild's process group id is its own pid, so a signal to the parent's
group does not reach it. None of them exit when stdin closes.
"""

import os
import signal
import sys


def ignore():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)


def pause():
    while True:
        signal.pause()


def main():
    ignore()
    report_read, report_write = os.pipe()
    child = os.fork()

    if child == 0:
        ignore()
        os.close(report_read)
        grandchild = os.fork()

        if grandchild == 0:
            os.setsid()
            ignore()
            os.write(report_write, f"{os.getpid()}\n".encode())
            os.close(report_write)
            pause()

        os.close(report_write)
        pause()

    os.close(report_write)
    line = b""

    while b"\n" not in line:
        chunk = os.read(report_read, 64)

        if not chunk:
            break

        line += chunk

    os.close(report_read)
    os.write(1, f"ready {os.getpid()} {line.decode().strip()}\n".encode())
    sys.stdout.flush()
    pause()


if __name__ == "__main__":
    main()
