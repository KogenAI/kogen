"""Keep a fixture's OS session alive until all its commands have terminated.

The session leader is deliberately not the CLI: project commands have their own
process groups, and may outlive the CLI. No host process-name matching is used.
"""
import json
import os
import signal
import subprocess
import sys
import threading
import time


class Cancelled(Exception):
    pass


def members():
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,stat="], text=True)
    result = []
    for line in output.splitlines():
        pid, status = line.split()
        pid = int(pid)
        if pid == os.getpid() or status.startswith("Z"):
            continue
        try:
            if os.getsid(pid) == os.getpid():
                result.append(pid)
        except ProcessLookupError:
            pass
    return result


def stop_members(sig, seconds):
    deadline = time.monotonic() + seconds
    while True:
        remaining = members()
        if not remaining:
            return
        for pid in remaining:
            try:
                # Recheck membership immediately before signalling.
                if os.getsid(pid) == os.getpid():
                    os.kill(pid, sig)
            except ProcessLookupError:
                pass
        if time.monotonic() >= deadline:
            raise RuntimeError(f"owned processes did not terminate: {remaining}")
        time.sleep(.02)


def session_main():
    custody, executable, *args = sys.argv[1:]
    os.setsid()
    child = None
    cancelling = False
    waiting = False

    def cancel(sig, _frame):
        nonlocal cancelling
        if child is not None and child.poll() is None:
            child.send_signal(sig)
        cancelling = True
        if waiting:
            raise Cancelled()

    # Install handlers before publishing readiness to the custodian.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, cancel)

    try:
        child = subprocess.Popen([executable, *args], stdin=subprocess.PIPE)
    except Exception as error:
        with open(os.path.join(custody, "ready"), "w") as f:
            json.dump({"error": str(error)}, f)
        with open(os.path.join(custody, "stopped"), "w") as f:
            f.write("stopped")
        return 70

    try:
        # Preserve Port stdin semantics, including EOF if the Port is closed.
        def input_reader():
            try:
                while data := os.read(0, 4096):
                    child.stdin.write(data)
                    child.stdin.flush()
                child.stdin.close()
                os.kill(os.getpid(), signal.SIGTERM)
            except (BrokenPipeError, OSError):
                pass

        threading.Thread(target=input_reader, daemon=True).start()
        with open(os.path.join(custody, "ready"), "w") as f:
            json.dump({}, f)
        # Cancellation during startup is retained too, before child.wait begins.
        waiting = True
        if cancelling:
            child.send_signal(signal.SIGTERM)
            raise Cancelled()
        status = child.wait()
    except Cancelled:
        waiting = False
        try:
            status = child.wait(timeout=16)
        except subprocess.TimeoutExpired:
            status = 70
    finally:
        waiting = False
        # Further signals must not interrupt the bounded, fixture-only finalizer.
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        try:
            stop_members(signal.SIGTERM, 2)
        except RuntimeError:
            stop_members(signal.SIGKILL, 3)
        child.wait()

    # The marker is proof of completed descendant cleanup, not just a closed Port.
    with open(os.path.join(custody, "stopped"), "w") as f:
        f.write("stopped")
    return status if status >= 0 else 128 - status


def main():
    # BEAM Ports launch process-group leaders, which cannot call setsid(). Keep
    # the Port process as a relay and create a distinct, retained session leader.
    leader = os.fork()
    if leader == 0:
        return session_main()

    def forward(sig, _frame):
        try:
            os.kill(leader, sig)
        except ProcessLookupError:
            pass

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    _, status = os.waitpid(leader, 0)
    return os.waitstatus_to_exitcode(status) % 256


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"fixture process custody failed: {error}", file=sys.stderr, flush=True)
        sys.exit(70)
