"""Tests for analysis.session_loader."""
import datetime
import json
import os
import tempfile
import unittest
from pathlib import Path

from analysis.config import Config
from analysis.session_loader import (
    Session,
    Turn,
    _cwd_to_slug,
    _load_jsonl,
    iter_sessions,
)

FIXTURES = Path(__file__).parent / "fixtures"


def _make_config(project_dir: Path) -> Config:
    return Config(
        since=datetime.date(2026, 1, 1),
        project_dir=project_dir,
    )


class TestCwdToSlug(unittest.TestCase):
    def test_slash_replaced(self) -> None:
        slug = _cwd_to_slug("/Users/alice/project")
        self.assertEqual(slug, "-Users-alice-project")

    def test_alnum_preserved(self) -> None:
        slug = _cwd_to_slug("/abc123/XYZ")
        self.assertEqual(slug, "-abc123-XYZ")

    def test_non_alnum_replaced_with_dash(self) -> None:
        # spaces, dots, underscores all become dashes
        slug = _cwd_to_slug("/my project/some.dir")
        self.assertNotIn(" ", slug)
        self.assertNotIn(".", slug)


class TestLoadJsonl(unittest.TestCase):
    def test_clean_file_loaded(self) -> None:
        turns = _load_jsonl(FIXTURES / "session_clean.jsonl")
        self.assertEqual(len(turns), 4)

    def test_malformed_line_skipped(self) -> None:
        turns = _load_jsonl(FIXTURES / "session_malformed.jsonl")
        # malformed.jsonl has 3 lines: valid, invalid, valid → 2 turns
        self.assertEqual(len(turns), 2)

    def test_nonexistent_file_returns_empty(self) -> None:
        turns = _load_jsonl(Path("/nonexistent/path.jsonl"))
        self.assertEqual(turns, [])

    def test_turn_fields_populated(self) -> None:
        turns = _load_jsonl(FIXTURES / "session_clean.jsonl")
        first = turns[0]
        self.assertEqual(first.kind, "assistant")
        self.assertEqual(first.cwd, "/tmp/project")
        self.assertIsNotNone(first.timestamp)
        self.assertEqual(len(first.tool_uses), 1)
        self.assertEqual(first.tool_uses[0].name, "Read")
        self.assertEqual(first.tool_uses[0].file_path, "lib/bar.ex")

    def test_user_content_str_becomes_user_text(self) -> None:
        # session_thrash.jsonl has a line with user content as str
        turns = _load_jsonl(FIXTURES / "session_thrash.jsonl")
        user_turns = [t for t in turns if t.kind == "user" and t.user_text is not None]
        self.assertGreater(len(user_turns), 0)

    def test_user_content_list_becomes_tool_results(self) -> None:
        turns = _load_jsonl(FIXTURES / "session_clean.jsonl")
        # second turn is a tool_result user turn
        result_turns = [t for t in turns if t.kind == "user" and t.tool_results]
        self.assertGreater(len(result_turns), 0)

    def test_tool_use_command_extracted(self) -> None:
        turns = _load_jsonl(FIXTURES / "session_thrash.jsonl")
        bash_turns = [
            t for t in turns if any(tu.name == "Bash" for tu in t.tool_uses)
        ]
        self.assertGreater(len(bash_turns), 0)
        bash_tu = bash_turns[0].tool_uses[0]
        self.assertIsNotNone(bash_tu.command)

    def test_is_error_flag_parsed(self) -> None:
        turns = _load_jsonl(FIXTURES / "session_thrash.jsonl")
        error_results = [
            tr
            for t in turns
            for tr in t.tool_results
            if tr.is_error
        ]
        self.assertGreater(len(error_results), 0)


class TestIterSessions(unittest.TestCase):
    def test_loads_sessions_from_project_dir(self) -> None:
        config = _make_config(FIXTURES)
        sessions = list(iter_sessions(config))
        # fixtures dir has: session_thrash, session_clean, session_malformed
        # malformed still loads (has 2 valid turns)
        names = {s.session_id for s in sessions}
        self.assertTrue(any("session_thrash" in n for n in names))
        self.assertTrue(any("session_clean" in n for n in names))

    def test_substrate_files_excluded(self) -> None:
        config = _make_config(FIXTURES)
        sessions = list(iter_sessions(config))
        names = {s.session_id for s in sessions}
        # failures.jsonl and gate-verdicts.jsonl must not be loaded as sessions
        self.assertFalse(any("failures" in n for n in names))
        self.assertFalse(any("gate-verdicts" in n for n in names))

    def test_empty_dir_yields_no_sessions(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config = _make_config(Path(tmpdir))
            sessions = list(iter_sessions(config))
            self.assertEqual(sessions, [])

    def test_turns_ordered(self) -> None:
        config = _make_config(FIXTURES)
        sessions = list(iter_sessions(config))
        for session in sessions:
            indices = [t.index for t in session.turns]
            # Indices reflect raw JSONL line positions — may skip lines on decode errors.
            # They must be non-decreasing (not necessarily contiguous).
            for i in range(len(indices) - 1):
                self.assertLess(indices[i], indices[i + 1])

    def test_production_mode_no_project_dir(self) -> None:
        # When project_dir is None and claude_projects_root doesn't exist → no sessions
        config = Config(
            since=datetime.date(2026, 1, 1),
            project_dir=None,
            claude_projects_root=Path("/nonexistent/projects"),
        )
        sessions = list(iter_sessions(config))
        self.assertEqual(sessions, [])


if __name__ == "__main__":
    unittest.main()
