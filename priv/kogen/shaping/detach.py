#!/usr/bin/env python3
"""Starts a Shaping runner detached from its caller.

Usage: detach.py LOG ARGV...

The runner gets a new session (so neither the client exiting nor its process
group being killed reaches it), no stdin, and LOG (appended) as stdout and
stderr. Prints the runner pid on stdout and exits without waiting.
"""

import subprocess
import sys


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: detach.py LOG ARGV...\n")
        return 2

    log_path, command = argv[1], argv[2:]

    with open(log_path, "ab") as log:
        process = subprocess.Popen(
            command,
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
        )

    sys.stdout.write("%d\n" % process.pid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
