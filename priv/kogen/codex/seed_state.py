#!/usr/bin/env python3
"""Seed a fresh operation's Codex state database as already backfilled.

Codex (0.159.0 and later) gates interactive startup on a rollout backfill of
its state database and gives up after a hard 30 seconds ("timed out waiting
for state db backfill"). A fresh operation database would otherwise re-index
every rollout ever written under the credential scope on each launch, so
startup would depend on the size of the user's history and on disk cache. An
operation owns its state and records its own sessions as they are created, so
the database is created here by the pinned Codex itself against an empty,
disposable CODEX_HOME (nothing to index, so the backfill completes at once)
and is moved into the operation's sqlite directory only when none exists.

Usage: seed_state.py EXECUTABLE SQLITE_HOME
Exit 0: SQLITE_HOME holds a complete database (already there or seeded).
Exit 1: not seeded; the caller keeps Codex's own first-start behavior.
"""

import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

DB = "state_5.sqlite"
# The empty-home backfill finishes in milliseconds; this only bounds a broken
# executable so a launch never waits on it.
SEED_DEADLINE_SECONDS = 20


def complete(directory):
    path = os.path.join(directory, DB)
    if not os.path.isfile(path):
        return False
    try:
        with sqlite3.connect("file:" + path + "?mode=ro", uri=True, timeout=1) as db:
            row = db.execute("SELECT status FROM backfill_state WHERE id = 1").fetchone()
        return bool(row) and row[0] == "complete"
    except sqlite3.Error:
        return False


def stop(process):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue


def seed(executable, target):
    parent = os.path.dirname(target)
    scratch = tempfile.mkdtemp(prefix=".seed-", dir=parent)
    try:
        home = os.path.join(scratch, "home")
        sqlite_dir = os.path.join(scratch, "sqlite")
        os.mkdir(home, 0o700)
        os.mkdir(sqlite_dir, 0o700)
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": home,
            "CODEX_HOME": home,
            "SQLITE_HOME": sqlite_dir,
        }
        process = subprocess.Popen(
            [
                executable,
                "--disable",
                "apps",
                "--disable",
                "plugins",
                "-c",
                'sqlite_home="%s"' % sqlite_dir,
                "-c",
                "check_for_update_on_startup=false",
                "app-server",
                "--stdio",
            ],
            cwd=scratch,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.monotonic() + SEED_DEADLINE_SECONDS
        try:
            while time.monotonic() < deadline and not complete(sqlite_dir):
                if process.poll() is not None:
                    break
                time.sleep(0.05)
            ready = complete(sqlite_dir)
        finally:
            try:
                process.stdin.close()
            except OSError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            if process.poll() is None:
                stop(process)
        if not ready or not complete(sqlite_dir):
            return False
        # Publish the database last, and only where none exists.
        names = sorted(os.listdir(sqlite_dir), key=lambda name: name.startswith(DB))
        for name in names:
            destination = os.path.join(target, name)
            if not os.path.lexists(destination):
                os.rename(os.path.join(sqlite_dir, name), destination)
        return complete(target)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main():
    executable, target = sys.argv[1], os.path.abspath(sys.argv[2])
    if os.path.lexists(os.path.join(target, DB)):
        return 0
    return 0 if seed(executable, target) else 1


if __name__ == "__main__":
    sys.exit(main())
