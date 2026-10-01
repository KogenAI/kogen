#!/usr/bin/env python3
"""Shared offline engine harness for the driver rehearsals.

The Elixir tests (shaping_evaluation_test.exs, shaping_smoke_rehearsal_test.exs)
build a compiled fixture with `Kogen.ShapingEvaluation.RehearsalFixture` and pass
its handoff file in KOGEN_REHEARSAL_ENGINE. This module turns that into a
per-test copy of the fixture, a driver module pointed at the real `mix
kogen.shape` engine, and scripts for `test/support/fake_shaping_controller`.
Only the provider, the Auditor and the Jev transport are fake.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRIVER_PATH = HERE / "driver.py"
HANDOFF_ENV = "KOGEN_REHEARSAL_ENGINE"
ENGINE_BOUND_SECONDS = 180


def handoff():
    path = os.environ.get(HANDOFF_ENV)
    if not path:
        return None
    return json.loads(Path(path).read_text())


def load_driver(name, runtime):
    """A fresh driver module bound to its own runtime directory."""
    previous = os.environ.get("KOGEN_SHAPING_EVALUATION_RUNTIME")
    os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = str(runtime)
    try:
        spec = importlib.util.spec_from_file_location(name, DRIVER_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        if previous is None:
            os.environ.pop("KOGEN_SHAPING_EVALUATION_RUNTIME", None)
        else:
            os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = previous
    return module


class EngineRehearsal(unittest.TestCase):
    """Base class: one copy of the compiled fixture and one driver per test."""

    def setUp(self):
        self.info = handoff()
        if self.info is None:
            self.skipTest(f"{HANDOFF_ENV} is not set; run through mix test")
        if os.environ.get("KOGEN_REHEARSAL_KEEP"):
            self.root = Path(tempfile.mkdtemp(prefix="kogen-engine-rehearsal-",
                                              dir=os.environ["KOGEN_REHEARSAL_KEEP"])).resolve()
            print(f"KEPT {self.root}", file=sys.stderr)
        else:
            self.temp = tempfile.TemporaryDirectory(prefix="kogen-engine-rehearsal-")
            self.addCleanup(self.temp.cleanup)
            self.root = Path(self.temp.name).resolve()
        self.runtime = self.root / "runtime"; self.runtime.mkdir()
        self.driver = load_driver("engine_rehearsal_driver", self.runtime)
        self.driver.MIX_COMMAND = list(self.info["mix_command"])
        self.driver.EVAL_COMMAND = list(self.info["eval_command"])
        self.driver.POLL_SECONDS = 0.3
        self.driver.MID_TURN_POLL_SECONDS = 0.1
        self.log_dir = self.root / "fake-log"
        self.driver.ENGINE_ENV = {**self.info["env"], "FAKE_SHAPING_LOG_DIR": str(self.log_dir)}
        self.spawns = []
        self.real_run = self.driver.subprocess.run

    def fixture(self, name, request):
        """A private copy of the compiled fixture with the case's request as README."""
        target = self.root / name
        shutil.copytree(self.info["fixture"], target, symlinks=True)
        (target / "README.md").write_text(f"# {name}\n\n## Current user request\n\n{request}\n")
        return target

    def template(self, name):
        return self.info["templates"][name]

    def scenarios_text(self, name="complete"):
        return (Path(self.template(name)) / "scenarios.yaml").read_text()

    def script(self, turns, **extra):
        path = self.root / f"script-{len(list(self.root.glob('script-*.json')))}.json"
        path.write_text(json.dumps({"turns": turns, **extra}))
        self.driver.ENGINE_ENV["FAKE_SHAPING_SCRIPT"] = str(path)
        return path

    def record_spawns(self):
        """Wrap subprocess.run so every argv the driver spawns is recorded."""
        driver_subprocess = self.driver.subprocess
        recorded = self.spawns
        real_run = self.real_run

        def run(argv, *args, **kwargs):
            recorded.append([str(part) for part in argv])
            return real_run(argv, *args, **kwargs)

        return unittest.mock.patch.object(driver_subprocess, "run", run)

    def case_spec(self, name, steps, *, end="ready", messages=()):
        """A case spec built in the test's own directory (files written for real)."""
        directory = self.root / "cases" / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "brief.md").write_text(self.brief(name) + "\n")
        for filename, text in messages:
            (directory / filename).write_text(text + "\n")
        return self.driver.validate_case_spec({"name": name, "dir": str(directory), "end": end, "steps": steps})

    def brief(self, name):
        return f"Rehearsal brief for {name}."



def spawn_violations(spawns):
    """Spawns that break the engine-only rule: any `expect`, or a `kogen.shape`
    command outside start/status/message/approve/cancel."""
    allowed_flags = {"--brief", "--approve", "--cancel", "--request-id", "--route", "--interface"}
    violations = []
    for argv in spawns:
        name = Path(argv[0]).name
        if name == "expect" or any(Path(part).suffix == ".exp" for part in argv):
            violations.append(f"expect transport spawned: {argv[:3]}")
            continue
        if "kogen.shape" in argv:
            rest = argv[argv.index("kogen.shape") + 1:]
            flags = [part for part in rest if part.startswith("--")]
            if any(flag not in allowed_flags for flag in flags):
                violations.append(f"unsupported shape flag: {rest}")
            if "--approve" in flags and "--cancel" in flags:
                violations.append(f"approve and cancel together: {rest}")
        elif name == "elixir" and "-e" in argv and "-S" not in argv:
            continue  # the driver's route-lookup eval (EVAL_COMMAND), never a Shaping launch
        elif name in ("mix", "elixir") and "run" not in argv and "compile" not in argv:
            violations.append(f"unexpected mix spawn: {argv[:6]}")
    return violations
