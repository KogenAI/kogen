#!/usr/bin/env python3
"""Run the interactive Codex compatibility probe under a real PTY.

The caller supplies an already-isolated environment.  This driver never reads
or creates credentials and records only terminal output and exit status.
"""
import codecs
import fcntl
import json
import os
import pty
import re
import select
import signal
import subprocess
import struct
import sys
import termios
import time


EXECUTION_SECONDS = 180.0
# Native Codex can still be closing its model-refresh and telemetry descendants
# after the terminal marker is rendered. Keep cleanup bounded, but give macOS
# enough time to reap the process-group leader after SIGKILL instead of
# reporting a false cleanup failure while the owned tree is already exiting.
CLEANUP_SECONDS = 30.0


class Screen:
    """Minimal incremental terminal model for locating rendered text.

    Native Codex streams an answer as fragments drawn at absolute cursor
    positions between unrelated redraws (status line, window title), so the
    escape-stripped byte stream need not contain the answer contiguously.
    Only cursor placement, erasure and printable text are modelled; every
    other control sequence is consumed without effect.
    """

    CSI = re.compile(r"\x1b\[([0-?]*)([ -/]*)([@-~])")
    OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

    def __init__(self, rows=40, columns=160):
        self.rows, self.columns = rows, columns
        self.grid, self.row, self.column, self.pending = {}, 0, 0, ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data):
        text = self.pending + self.decoder.decode(data)
        self.pending = ""
        index = 0
        while index < len(text):
            char = text[index]
            if char == "\x1b":
                match = self.CSI.match(text, index) or self.OSC.match(text, index)
                if match:
                    if match.re is self.CSI:
                        self._csi(match.group(1), match.group(3))
                    index = match.end()
                    continue
                if self._incomplete(text[index:]):
                    self.pending = text[index:]
                    return
                index += 2
                continue
            if char == "\r":
                self.column = 0
            elif char == "\n":
                self.row += 1
            elif char == "\b":
                self.column = max(0, self.column - 1)
            elif char >= " ":
                self.grid.setdefault(self.row, {})[self.column] = char
                self.column += 1
            index += 1

    @staticmethod
    def _incomplete(tail):
        if len(tail) < 2:
            return True
        if tail[1] == "[":
            return re.fullmatch(r"\x1b\[[0-?]*[ -/]*", tail) is not None
        if tail[1] == "]":
            return "\x07" not in tail and "\x1b\\" not in tail
        return False

    def _csi(self, parameters, final):
        private = parameters.startswith("?")
        values = [int(value) if value.isdigit() else None
                  for value in parameters.lstrip("<=>?").split(";")] if parameters else []
        first = values[0] if values and values[0] is not None else None
        if private:
            if final in "hl" and first in (47, 1047, 1049):
                self.grid = {}
            return
        if final in "Hf":
            row = values[0] if values and values[0] else 1
            column = values[1] if len(values) > 1 and values[1] else 1
            self.row, self.column = row - 1, column - 1
        elif final == "A":
            self.row = max(0, self.row - (first or 1))
        elif final in "Be":
            self.row += first or 1
        elif final in "Ca":
            self.column += first or 1
        elif final == "D":
            self.column = max(0, self.column - (first or 1))
        elif final in "G`":
            self.column = (first or 1) - 1
        elif final == "d":
            self.row = (first or 1) - 1
        elif final == "E":
            self.row, self.column = self.row + (first or 1), 0
        elif final == "F":
            self.row, self.column = max(0, self.row - (first or 1)), 0
        elif final == "K":
            self._erase_line(first or 0)
        elif final == "J":
            mode = first or 0
            if mode in (2, 3):
                self.grid = {}
            else:
                self._erase_line(mode)
                for row in list(self.grid):
                    if (mode == 0 and row > self.row) or (mode == 1 and row < self.row):
                        del self.grid[row]
        elif final == "X":
            line = self.grid.get(self.row, {})
            for column in range(self.column, self.column + (first or 1)):
                line.pop(column, None)

    def _erase_line(self, mode):
        line = self.grid.get(self.row, {})
        for column in list(line):
            if mode == 2 or (mode == 0 and column >= self.column) or (mode == 1 and column <= self.column):
                del line[column]

    def lines(self):
        for row in sorted(self.grid):
            line = self.grid[row]
            if line:
                yield "".join(line.get(column, " ") for column in range(max(line) + 1))

    def contains(self, marker):
        return any(marker in line for line in self.lines())


def seconds(name, default):
    try:
        return max(0.1, float(os.environ.get(name, default)))
    except ValueError:
        return default


def wait_nonblocking(pid):
    try:
        waited, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return "already_reaped", None
    return ("reaped", os.waitstatus_to_exitcode(status)) if waited else ("running", None)


def group_empty(pid):
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        # A zero-signal EPERM means this process cannot signal any member of
        # the group.  The ps-based quiescence check remains authoritative when
        # it is available, but do not turn an un-signalable group into a
        # cleanup failure by itself.
        return True
    return False


def group_quiescent(pid):
    """A killed grandchild may briefly be a zombie owned by init, not live work."""
    try:
        listing = subprocess.run(
            ["ps", "-eo", "pid=,pgid=,stat="], text=True, capture_output=True, timeout=1, check=True
        ).stdout.splitlines()
        for line in listing:
            fields = line.split()
            if len(fields) >= 3 and int(fields[1]) == pid and "Z" not in fields[2]:
                return False
        return True
    except (OSError, subprocess.SubprocessError, ValueError):
        return group_empty(pid)


def signal_group_members(pid, sig, attempts):
    """Fall back to the observed owned process group when killpg is denied."""
    label = signal.Signals(sig).name
    try:
        listing = subprocess.run(
            ["ps", "-eo", "pid=,pgid="], text=True, capture_output=True, timeout=1, check=True
        ).stdout.splitlines()
        members = [int(fields[0]) for line in listing if len(fields := line.split()) >= 2
                   and int(fields[1]) == pid and int(fields[0]) != os.getpid()]
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        attempts.append({"signal": label, "target": "group_members", "outcome": "inspect_failed", "error": str(error)})
        return
    for member in members:
        try:
            os.kill(member, sig)
            attempts.append({"signal": label, "target": "group_member", "pid": member, "outcome": "sent"})
        except ProcessLookupError:
            attempts.append({"signal": label, "target": "group_member", "pid": member, "outcome": "gone"})
        except (PermissionError, OSError) as error:
            attempts.append({"signal": label, "target": "group_member", "pid": member, "outcome": "failed", "error": str(error)})


def signal_owned(pid, sig, attempts):
    label = signal.Signals(sig).name
    try:
        os.killpg(pid, sig)
        attempts.append({"signal": label, "target": "group", "outcome": "sent"})
        return True, None
    except (PermissionError, ProcessLookupError, OSError) as error:
        attempts.append({"signal": label, "target": "group", "outcome": "failed", "error": str(error)})
        signal_group_members(pid, sig, attempts)
    # Do not direct-signal a PID after waitpid has established it is reaped.
    # Keep that observed status for the receipt instead of losing it in fallback.
    state, exit_status = wait_nonblocking(pid)
    if state != "running":
        attempts.append({"signal": label, "target": "child", "outcome": "not_needed"})
        return False, exit_status
    try:
        os.kill(pid, sig)
        attempts.append({"signal": label, "target": "child", "outcome": "sent"})
        return True, None
    except (PermissionError, ProcessLookupError, OSError) as error:
        attempts.append({"signal": label, "target": "child", "outcome": "failed", "error": str(error)})
        return False, None


def drain_master(master, chunks, terminal_errors, limit=1024 * 1024):
    """Drain pending PTY output so a chatty child cannot block on its writer."""
    if master is None:
        return
    try:
        flags = fcntl.fcntl(master, fcntl.F_GETFL)
        fcntl.fcntl(master, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    except OSError as error:
        terminal_errors.append(str(error))
        return
    drained = 0
    while drained < limit:
        try:
            ready, _, _ = select.select([master], [], [], 0)
        except (OSError, ValueError) as error:
            terminal_errors.append(str(error))
            return
        if not ready:
            return
        try:
            data = os.read(master, min(65536, limit - drained))
        except BlockingIOError:
            return
        except OSError as error:
            # PTY masters report EIO once the slave has gone away.
            if getattr(error, "errno", None) != 5:
                terminal_errors.append(str(error))
            return
        if not data:
            return
        chunks.append(data)
        drained += len(data)


def cleanup(pid, attempts, deadline, master=None, chunks=None, terminal_errors=None):
    chunks = chunks if chunks is not None else []
    terminal_errors = terminal_errors if terminal_errors is not None else []
    # Read what is already buffered before bounded signal escalation. Keep the
    # master open while TERM/KILL are recorded so a child that ignores HUP
    # still exercises the escalation path; hang it up immediately after the
    # final signal to release any flooding writer.
    drain_master(master, chunks, terminal_errors)
    exit_status = None
    for sig in (signal.SIGTERM, signal.SIGKILL):
        state, observed = wait_nonblocking(pid)
        if observed is not None:
            exit_status = observed
        if state != "running" and group_quiescent(pid):
            return True, exit_status
        if sig == signal.SIGKILL and master is not None:
            try:
                os.close(master)
                attempts.append({"action": "pty_hangup", "outcome": "closed"})
                master = None
            except OSError as error:
                attempts.append({"action": "pty_hangup", "outcome": "failed", "error": str(error)})
        _, observed = signal_owned(pid, sig, attempts)
        if observed is not None:
            exit_status = observed
        signal_deadline = deadline if sig == signal.SIGKILL else min(deadline, time.monotonic() + max(0.1, (deadline - time.monotonic()) / 2))
        while time.monotonic() < signal_deadline:
            state, observed = wait_nonblocking(pid)
            if observed is not None:
                exit_status = observed
            if state != "running" and group_quiescent(pid):
                return True, exit_status
            drain_master(master, chunks, terminal_errors)
            time.sleep(0.05)
    state, observed = wait_nonblocking(pid)
    if observed is not None:
        exit_status = observed
    attempts.append({"action": "bounded_cleanup", "outcome": "timed_out", "child_state": state, "group_empty": group_empty(pid), "group_quiescent": group_quiescent(pid)})
    return False, exit_status


def write_receipt(path, payload):
    try:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True)
        return None
    except OSError as error:
        print("Kogen compatibility receipt write failed: " + str(error), file=sys.stderr)
        return str(error)


def main():
    if len(sys.argv) < 4:
        print("usage: pty_driver.py EXECUTABLE RECEIPT MARKER [ARGS...]", file=sys.stderr)
        return 2
    executable, receipt_path, marker, *args = sys.argv[1:]
    chunks, attempts, terminal_errors = [], [], []
    matched = timed_out = cleanup_ok = receipt_ok = cancelled = False
    trust_answered = False
    trust_ready_at = None
    screen = Screen()
    exit_status = None
    pid = master = None
    previous_handlers = {}

    def cancelled_by(_sig, _frame):
        nonlocal cancelled
        cancelled = True
        raise InterruptedError("owned PTY driver cancelled")

    try:
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[sig] = signal.signal(sig, cancelled_by)
        pid, master = pty.fork()
        if pid == 0:
            for sig in previous_handlers:
                signal.signal(sig, signal.SIG_DFL)
            os.environ["TERM"] = "xterm-256color"
            try:
                os.execv(executable, [executable, *args])
            except OSError as error:
                try:
                    os.write(2, ("Kogen compatibility startup failed: " + str(error) + "\n").encode())
                finally:
                    os._exit(127)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
        deadline, stop_deadline = time.monotonic() + seconds("KOGEN_PTY_EXECUTION_TIMEOUT", EXECUTION_SECONDS), None
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], min(0.2, max(0, deadline - time.monotonic())))
            if ready:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    # A PTY EIO may mean the child naturally exited after its marker.
                    terminal_errors.append(str(error))
                    state, status = wait_nonblocking(pid)
                    if state != "running":
                        exit_status = status
                        break
                    data = b""
                if data:
                    chunks.append(data)
                    screen.feed(data)
                    if b"\x1b[6n" in data:
                        try:
                            os.write(master, b"\x1b[1;1R")
                        except OSError as error:
                            terminal_errors.append(str(error))
                    text = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", b"".join(chunks))
                    fixture = os.environ.get("KOGEN_COMPATIBILITY_TRUST_FIXTURE")
                    legacy_trust_prompt = (
                        b"Yes, continue" in text and b"Press enter to continue" in text
                    )
                    # Native 0.156.1 introduced the "Trust this folder?"
                    # screen. Keep this bounded recognition for the pinned
                    # 0.158.0 compatibility fixture; live-native determines
                    # whether that CLI still presents it. Its first option
                    # is "Trust and continue". The CLI
                    # positions the title's words with cursor
                    # moves rather than spaces, so compare whitespace-free text;
                    # the "enter continue" footer is drawn last.
                    compact = re.sub(rb"\s+", b"", text)
                    current_trust_prompt = (
                        b"Trustthisfolder?" in compact and b"Trustandcontinue" in compact
                        and b"entercontinue" in compact
                    )
                    if (not trust_answered and trust_ready_at is None and fixture
                            and os.path.realpath(fixture) == os.path.realpath(os.getcwd())
                            and os.environ.get("KOGEN_PROJECT_ROOT") == fixture
                            and (legacy_trust_prompt or current_trust_prompt)):
                        # Native Codex draws protected onboarding screens before
                        # discard_pending_input_before_interactive_screen (a drain
                        # bounded to one second in tui/input_boundary.rs). Match
                        # the public Shape driver's settling delay so Enter is
                        # not discarded. Keep reading terminal queries meanwhile.
                        trust_ready_at = time.monotonic() + 2.0
                        attempts.append({"action": "fixture_trust", "outcome": "rendered"})
                    # A streamed answer can arrive as fragments positioned
                    # between redraws; match the rendered screen as well.
                    if not matched and (marker.encode() in text or screen.contains(marker)):
                        matched, stop_deadline = True, time.monotonic() + 1.0
                        state, status = wait_nonblocking(pid)
                        if state != "running":
                            exit_status = status
                            break
                        try:
                            os.write(master, b"\x03")
                            attempts.append({"signal": "SIGINT", "target": "terminal", "outcome": "sent"})
                        except OSError as error:
                            terminal_errors.append(str(error))
                            attempts.append({"signal": "SIGINT", "target": "terminal", "outcome": "failed", "error": str(error)})
            if trust_ready_at is not None and not trust_answered and time.monotonic() >= trust_ready_at:
                os.write(master, b"\r")
                trust_answered = True
                attempts.append({"action": "fixture_trust", "outcome": "answered"})
            state, status = wait_nonblocking(pid)
            if state != "running":
                exit_status = status
                break
            if stop_deadline is not None and time.monotonic() >= stop_deadline:
                break
        else:
            timed_out = True
    except BaseException as error:
        terminal_errors.append("driver error: " + repr(error))
    finally:
        for sig in previous_handlers:
            signal.signal(sig, signal.SIG_IGN)
        if pid is not None:
            cleanup_ok, cleanup_status = cleanup(
                pid,
                attempts,
                time.monotonic() + seconds("KOGEN_PTY_CLEANUP_TIMEOUT", CLEANUP_SECONDS),
                master,
                chunks,
                terminal_errors,
            )
            # cleanup may own the PTY hangup after SIGKILL; avoid reporting
            # that intentional close as a second close failure below.
            if any(
                item.get("action") == "pty_hangup" and item.get("outcome") == "closed"
                for item in attempts
            ):
                master = None
            if exit_status is None:
                exit_status = cleanup_status
        if master is not None:
            try:
                os.close(master)
            except OSError as error:
                terminal_errors.append(str(error))
        payload = {"marker": matched, "native_exit": exit_status, "cleanup": {"ok": cleanup_ok, "attempts": attempts}, "timed_out": timed_out, "cancelled": cancelled, "trust_answered": trust_answered, "terminal_errors": terminal_errors, "output": b"".join(chunks).decode("utf-8", "replace")}
        receipt_error = write_receipt(receipt_path, payload)
        receipt_ok = receipt_error is None
        if receipt_error:
            payload["receipt_error"] = receipt_error
        for sig, previous in previous_handlers.items():
            signal.signal(sig, previous)
    return 0 if matched and cleanup_ok and receipt_ok and not cancelled else 1


if __name__ == "__main__":
    sys.exit(main())
