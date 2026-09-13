#!/usr/bin/env python3
"""Focused provenance-state controls for the shaping evaluation driver."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import subprocess
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
DRIVER_PATH = HERE / "driver.py"


class DraftStateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kogen-draft-state-")
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.old_runtime = os.environ.get("KOGEN_SHAPING_EVALUATION_RUNTIME")
        os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = str(self.runtime)
        spec = importlib.util.spec_from_file_location("draft_state_driver", DRIVER_PATH)
        self.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.driver)

    def tearDown(self):
        if self.old_runtime is None:
            os.environ.pop("KOGEN_SHAPING_EVALUATION_RUNTIME", None)
        else:
            os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = self.old_runtime
        self.temp.cleanup()

    def draft_path(self):
        draft = self.root / "fixture/.kogen/intents/drafts/csv"
        draft.mkdir(parents=True)
        return draft / "intent.yaml"

    def state(self):
        out = self.root / "out"
        out.mkdir(exist_ok=True)
        self.driver.write_draft_state(self.root / "fixture", "csv", out)
        return json.loads((out / "draft-state.json").read_text())

    def test_reads_flow_map_provenance_with_the_supported_yaml_parser(self):
        self.draft_path().write_text(
            'id: "flow-draft"\nstatus: draft\n'
            'shaped_against: {branch: "main", head: "frozen-head"}\n'
            'shaping: {started: "first-visit"}\n'
            'shaping_continuations: [{started: "fresh-visit"}]\n'
        )

        self.assertEqual(
            {
                "intent_id": "flow-draft",
                "baseline": {"branch": "main", "head": "frozen-head"},
                "visit_id": "fresh-visit",
                "unapproved": True,
            },
            self.state(),
        )

    def test_block_and_json_forms_preserve_the_same_provenance(self):
        path = self.draft_path()
        data = {"id": "same-id", "status": "draft", "shaped_against": {"branch": "main", "head": "head"},
                "shaping": {"started": "first"}}
        path.write_text(json.dumps(data))
        expected = self.state()
        path.write_text("id: same-id\nstatus: draft\nshaped_against:\n  branch: main\n  head: head\nshaping:\n  started: first\n")
        self.assertEqual(expected, self.state())
        self.assertEqual("first", expected["visit_id"])
        self.assertEqual("head", expected["baseline"]["head"])

    def test_malformed_nonmap_or_missing_yaml_never_yields_partial_provenance(self):
        path = self.draft_path()
        for content, kind in (('id: "partial"\nshaped_against: {branch: "main"\n', "malformed YAML"), ('- one\n- two\n', "non-map YAML")):
            path.write_text(content)
            with self.assertRaises(RuntimeError) as caught:
                self.state()
            self.assertEqual(kind, caught.exception.kind)
            self.assertIn(str(path), str(caught.exception))
            self.assertFalse((self.root / "out/draft-state.json").exists())
        path.unlink()
        with self.assertRaises(RuntimeError) as caught:
            self.state()
        self.assertIn(str(path), str(caught.exception))
        self.assertFalse((self.root / "out/draft-state.json").exists())

    def test_incomplete_or_approved_original_cannot_emit_a_state(self):
        path = self.draft_path()
        original = {"id": "original", "status": "draft",
                    "shaped_against": {"branch": "main", "head": "head"},
                    "shaping": {"started": "first"}}
        for key in ("id", "shaped_against", "shaping"):
            bad = dict(original); bad.pop(key)
            path.write_text(json.dumps(bad))
            with self.assertRaises(RuntimeError): self.state()
            self.assertFalse((self.root / "out/draft-state.json").exists())
        original["status"] = "approved"
        path.write_text(json.dumps(original))
        with self.assertRaises(RuntimeError): self.state()
        self.assertFalse((self.root / "out/draft-state.json").exists())

    def test_parser_process_failures_preserve_diagnostics(self):
        path = self.draft_path(); path.write_text('id: original\n')
        for kind, result in (
            ("parser subprocess nonzero", subprocess.CompletedProcess(["parser"], 19, b"bounded stdout", b"specific stderr")),
            ("malformed parser JSON", subprocess.CompletedProcess(["parser"], 0, b"not JSON", b"decoder stderr")),
            ("malformed parser JSON", subprocess.CompletedProcess(["parser"], 0, b"\xff", b"invalid encoding")),
            ("non-map YAML", subprocess.CompletedProcess(["parser"], 0, b"[]", b"")),
        ):
            with patch.object(self.driver.subprocess, "run", return_value=result):
                with self.assertRaises(RuntimeError) as caught:
                    self.driver.parse_yaml_mapping(path)
            self.assertEqual(kind, caught.exception.kind)
            self.assertIn(str(path), str(caught.exception))
            if result.stderr:
                self.assertIn(result.stderr.decode(), str(caught.exception))
        timeout = subprocess.TimeoutExpired(["parser"], 30, output=b"partial", stderr=b"timed out")
        with patch.object(self.driver.subprocess, "run", side_effect=timeout):
            with self.assertRaises(RuntimeError) as caught:
                self.driver.parse_yaml_mapping(path)
        self.assertEqual("parser subprocess timeout", caught.exception.kind)
        self.assertIn("partial", str(caught.exception))
        self.assertIn(str(path), str(caught.exception))

    def test_missing_explicit_dependency_fails_in_private_build_environment(self):
        path = self.draft_path(); path.write_text('id: original\n')
        empty = self.root / "empty-ebin"; empty.mkdir()
        with patch.dict(os.environ, {
            "MIX_BUILD_PATH": str(self.root / "private-build"),
            "KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS": json.dumps([str(empty)]),
        }):
            with self.assertRaises(RuntimeError) as caught:
                self.driver.parse_yaml_mapping(path)
        self.assertIn(str(path), str(caught.exception))
        self.assertEqual("parser dependency unavailable", caught.exception.kind)
        self.assertFalse((self.root / "private-build").exists())

    def test_compact_csv_briefs_keep_only_cli_scope(self):
        self.assertIn("CSV normalization", self.driver.CSV_FLAWED)
        self.assertIn("CSV normalization", self.driver.CSV_COMPLETE)
        self.assertNotIn("chart", self.driver.CSV_FLAWED.lower())


if __name__ == "__main__":
    unittest.main()
