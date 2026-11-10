#!/usr/bin/env python3
"""Stay up after stdin closes, and keep a child in this process group.

The first argument, when it is not ``quiet``, is a pid file. ``quiet`` skips
the stdout line so a relay that reads JSONL does not see it. The line is
``ready <parent-pid> <child-pid>``. Both processes ignore SIGTERM. The child
blocks on a pipe this process holds open, so stdin EOF does not end it.
"""

import os
import signal
import sys


def main():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    args = sys.argv[1:]
    quiet = "quiet" in args
    pidfile = next((arg for arg in args if arg != "quiet"), None)
    held_read, held_write = os.pipe()
    child = os.fork()

    if child == 0:
        os.close(held_write)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)

        try:
            os.read(held_read, 1)
        except OSError:
            pass

        while True:
            signal.pause()
    else:
        os.close(held_read)
        line = f"ready {os.getpid()} {child}\n"

        if not quiet:
            os.write(1, line.encode())

        if pidfile:
            with open(pidfile, "w", encoding="utf-8") as handle:
                handle.write(line)

        while True:
            signal.pause()


if __name__ == "__main__":
    main()
