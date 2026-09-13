#!/usr/bin/env python3
"""Non-provider regression controls for the public Shape transport scripts."""
import os
import pathlib
import subprocess
import tempfile
import time
import unittest


HERE = pathlib.Path(__file__).resolve().parent


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kogen-shaping-transport-")
        self.root = pathlib.Path(self.temp.name)
        self.fixture = self.root / "fixture"
        self.fixture.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.temp.cleanup()

    def fake(self, name, *, trust):
        path = self.bin / name
        if trust:
            body = (
                "python3 -u - <<'PY'\n"
                "import os, select, time, tty\n"
                "fd = os.open('/dev/tty', os.O_RDWR)\n"
                "tty.setraw(fd)\n"
                "time.sleep(1.2)\n"
                "os.write(fd, b'Yes, con')\n"
                "time.sleep(0.1)\n"
                "os.write(fd, b'tinue\\x1b[0m\\nPress enter to continue')\n"
                "deadline = time.monotonic() + 1.0\n"
                "while time.monotonic() < deadline:\n"
                "    if select.select([fd], [], [], 0.05)[0]: os.read(fd, 1024)\n"
                "answer = os.read(fd, 1)\n"
                "assert answer in (b'\\r', b'\\n'), answer\n"
                "os.write(fd, b'TRUST_ACK\\n')\n"
                "while True:\n"
                "    answer = os.read(fd, 1)\n"
                "    if answer in (b'\\r', b'\\n'): os.write(fd, b'SECOND_INPUT\\n')\n"
                "    elif answer == b'\\x03': break\n"
                "PY\n"
            )
        else:
            body = "printf 'READY_WITHOUT_TRUST\n'\nwhile :; do sleep 1; done\n"
        path.write_text("#!/bin/sh\ntrap 'exit 0' INT TERM\n" + body)
        path.chmod(0o755)

    def launch(self, command):
        env = {**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"}
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
        self.processes.append(process)
        return process

    def wait_for(self, log, process, marker):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            contents = log.read_text(errors="replace") if log.exists() else ""
            if marker in contents:
                return contents
            if process.poll() is not None:
                self.fail(process.stdout.read())
            time.sleep(0.05)
        self.fail(log.read_text(errors="replace") if log.exists() else f"transport did not emit {marker}")

    def stop(self, process, stop_path):
        stop_path.write_text("stop\n")
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)

    def test_shape_acknowledges_split_ansi_trust_once(self):
        self.fake("mix", trust=True)
        mailbox = self.root / "mailbox"
        mailbox.mkdir()
        log = self.root / "shape-pty.log"
        process = self.launch(["expect", str(HERE / "shape_transport.exp"), str(self.fixture), str(log), str(mailbox), ""])
        # Startup and widget input readiness are distinct bounded phases.
        # Concurrent fixture startup must not consume the acknowledgement window.
        self.wait_for(log, process, "Press enter to continue")
        self.wait_for(log, process, "TRUST_ACK")
        time.sleep(0.25)
        self.assertNotIn("SECOND_INPUT", log.read_text(errors="replace"))
        self.stop(process, mailbox / "stop")

    def test_resume_acknowledges_split_ansi_trust_once(self):
        self.fake("codex", trust=True)
        prompt = self.root / "prompt.txt"
        prompt.write_text("fixture reply\n")
        stop = self.root / "resume-stop"
        log = self.root / "resume-pty.log"
        process = self.launch(["expect", str(HERE / "resume_transport.exp"), str(self.fixture), "session-id", str(prompt), str(stop), str(log), "fake-model", "low"])
        # Startup and widget input readiness are distinct bounded phases.
        # Concurrent fixture startup must not consume the acknowledgement window.
        self.wait_for(log, process, "Press enter to continue")
        self.wait_for(log, process, "TRUST_ACK")
        time.sleep(0.25)
        self.assertNotIn("SECOND_INPUT", log.read_text(errors="replace"))
        self.stop(process, stop)

    def test_shape_stops_promptly_without_a_trust_widget(self):
        self.fake("mix", trust=False)
        mailbox = self.root / "mailbox"
        mailbox.mkdir()
        log = self.root / "shape-pty.log"
        process = self.launch(["expect", str(HERE / "shape_transport.exp"), str(self.fixture), str(log), str(mailbox), ""])
        self.wait_for(log, process, "READY_WITHOUT_TRUST")
        self.stop(process, mailbox / "stop")


if __name__ == "__main__":
    unittest.main()
