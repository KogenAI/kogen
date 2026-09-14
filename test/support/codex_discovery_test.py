"""Synthetic native checks for the hostile discovery compatibility boundary."""
import importlib.util
import os
import subprocess
import tomllib
import tempfile
import unittest
from pathlib import Path
from unittest import mock


DISCOVERY = Path(__file__).parents[2] / "priv/kogen/codex/discovery.py"
spec = importlib.util.spec_from_file_location("kogen_codex_discovery", DISCOVERY)
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


FAKE_NATIVE = """#!/usr/bin/env python3
import os, sys
hostile = os.environ.get('HOME', '').endswith('-hostile-home')
missing = '--missing-project' in sys.argv
if sys.argv[-3:] == ['mcp', 'get', 'hostile']:
    pass
if 'mcp' in sys.argv:
    if hostile:
        print('{"name":"hostile"}')
        raise SystemExit(0)
    print("Error: No MCP server named 'hostile' found.", file=sys.stderr)
    raise SystemExit(1)
if hostile:
    print('personal-discovery-sentinel')
elif not missing:
    print('project-discovery-sentinel')
raise SystemExit(0)
"""


class DiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fixture = Path(self.tmp.name) / "fixture"
        self.fixture.mkdir()
        self.native = Path(self.tmp.name) / "fake-native"
        self.native.write_text(FAKE_NATIVE)
        self.native.chmod(0o700)

    def tearDown(self):
        self.tmp.cleanup()

    def seed(self):
        return discovery.seed(self.fixture, {})

    def test_seed_makes_sibling_hostile_home_and_project_only_context(self):
        result = self.seed()
        home = Path(result["home"])
        self.assertEqual(home.parent, self.fixture.resolve().parent)
        self.assertFalse(str(home).startswith(str(self.fixture.resolve()) + os.sep))
        self.assertFalse((self.fixture / "AGENTS.md").exists())
        self.assertIn("name: project-discovery-sentinel", (self.fixture / ".agents/skills/project-context/SKILL.md").read_text())
        self.assertIn("personal-discovery-sentinel", (home / ".codex/AGENTS.md").read_text())
        settings = tomllib.loads((home / ".codex/config.toml").read_text())
        self.assertNotIn("profile", settings)
        self.assertTrue((home / ".codex/personal-hostile.config.toml").is_file())
        self.assertTrue((home / "bin/hostile-mcp").stat().st_mode & 0o100)

    def test_probe_requires_isolated_positive_and_hostile_negative_controls(self):
        context = self.seed()
        private = Path(self.tmp.name) / "isolated-home"
        private.mkdir()
        with mock.patch.dict(os.environ, {"HOME": str(private), "CODEX_HOME": str(private), "PATH": os.environ["PATH"]}, clear=False):
            receipt = discovery.probe(str(self.native), self.fixture, {"root_args": ["--root"]}, ["--isolated"])
        self.assertTrue(receipt["safe_project_visible"])
        self.assertTrue(receipt["safe_personal_absent"])
        self.assertTrue(receipt["safe_hook_marker_absent"])
        self.assertTrue(receipt["hostile_personal_visible"])
        self.assertTrue(receipt["hostile_mcp_present"])
        self.assertFalse(Path(context["marker"]).exists())
        self.assertFalse(Path(context["hook_marker"]).exists())

    def test_probe_rejects_personal_hook_startup_in_isolated_control(self):
        context = self.seed()
        original = discovery._run
        calls = []
        def leak_hook(command, fixture, environment):
            calls.append(command)
            if len(calls) == 1:
                Path(context["hook_marker"]).touch()
            return original(command, fixture, environment)
        private = Path(self.tmp.name) / "isolated-home"
        private.mkdir()
        with mock.patch.dict(os.environ, {"HOME": str(private), "CODEX_HOME": str(private)}, clear=False):
            with mock.patch.object(discovery, "_run", side_effect=leak_hook):
                with self.assertRaises(discovery.DiscoveryError):
                    discovery.probe(str(self.native), self.fixture, {}, [])

    def test_missing_mcp_requires_explicit_native_not_found_error(self):
        for text in ["Error: No MCP server named 'hostile' found.\n", "No MCP server named hostile"]:
            self.assertTrue(discovery._explicit_missing_mcp(subprocess.CompletedProcess([], 1, "", text)))
        for text in ["failed to load configuration", "No MCP server named 'other' found.", "unknown command"]:
            self.assertFalse(discovery._explicit_missing_mcp(subprocess.CompletedProcess([], 1, "", text)))
        self.assertFalse(discovery._explicit_missing_mcp(subprocess.CompletedProcess([], 0, "", "No MCP server named hostile")))

    def test_probe_fails_when_native_prompt_omits_project_sentinel(self):
        self.seed()
        private = Path(self.tmp.name) / "isolated-home"
        private.mkdir()
        with mock.patch.dict(os.environ, {"HOME": str(private), "CODEX_HOME": str(private), "PATH": os.environ["PATH"]}, clear=False):
            with self.assertRaises(discovery.DiscoveryError):
                discovery.probe(str(self.native), self.fixture, {}, ["--missing-project"])


if __name__ == "__main__":
    unittest.main()
