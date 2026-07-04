"""Tests for the stdlib registry parser against the real shared/enforcement/registry.yaml."""
import tempfile
import unittest
from pathlib import Path

from analysis.counters.forbidden_bash import _parse_registry

REPO_ROOT = Path(__file__).parent.parent.parent
REGISTRY = REPO_ROOT / "shared" / "enforcement" / "registry.yaml"


class TestForbiddenRegistry(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(
            REGISTRY.exists(), f"registry.yaml not found at {REGISTRY}"
        )
        self.denials = _parse_registry(REGISTRY)
        self.denial_ids = {d[0] for d in self.denials}

    def test_no_cat_pipe_selected(self) -> None:
        self.assertIn("no-cat-pipe", self.denial_ids)

    def test_no_git_stash_selected(self) -> None:
        self.assertIn("no-git-stash", self.denial_ids)

    def test_no_python_json_selected(self) -> None:
        self.assertIn("no-python-json", self.denial_ids)

    def test_committer_allowlist_excluded(self) -> None:
        """mode:allowlist entries must be excluded — they invert denial semantics."""
        self.assertNotIn("committer-bash-allowlist", self.denial_ids)

    def test_patterns_are_valid_regex(self) -> None:
        """All extracted patterns must compile without error."""
        import re

        for denial_id, patterns in self.denials:
            for pat in patterns:
                try:
                    re.compile(pat)
                except re.error as e:
                    self.fail(
                        f"Pattern for {denial_id!r} failed to compile: {e}\n"
                        f"Pattern: {pat!r}"
                    )

    def test_no_cat_pipe_matches_forbidden_command(self) -> None:
        """The no-cat-pipe pattern must match the canonical forbidden form."""
        import re

        no_cat_pipe = next(
            (patterns for id_, patterns in self.denials if id_ == "no-cat-pipe"),
            None,
        )
        self.assertIsNotNone(no_cat_pipe)
        cmd = "cat lib/foo.ex | grep def"
        matched = all(re.search(p, cmd) for p in no_cat_pipe)  # type: ignore[union-attr]
        self.assertTrue(matched, f"no-cat-pipe pattern did not match: {cmd!r}")

    def test_no_git_stash_matches_forbidden_command(self) -> None:
        """The no-git-stash pattern must match git stash invocations."""
        import re

        no_git_stash = next(
            (patterns for id_, patterns in self.denials if id_ == "no-git-stash"),
            None,
        )
        self.assertIsNotNone(no_git_stash)
        cmd = "git stash"
        matched = all(re.search(p, cmd) for p in no_git_stash)  # type: ignore[union-attr]
        self.assertTrue(matched)

    def test_exactly_three_universal_denials(self) -> None:
        """Guard against future registry drift — update this test if new universal Bash denials added."""
        self.assertEqual(
            len(self.denials),
            3,
            f"Expected 3 universal Bash denials, got {len(self.denials)}: "
            f"{sorted(self.denial_ids)}",
        )


class TestForbiddenRegistryMalformedPattern(unittest.TestCase):
    """A malformed regex in registry.yaml must raise immediately at parse time
    (fail loud), naming the offending counter id and pattern — never silently
    disable that counter later inside the per-line matching loop.
    """

    BAD_REGISTRY_YAML = """\
- id: bad-pattern-counter
  tool_guard: Bash
  role: "*"
  match: "unclosed_paren("
"""

    def test_malformed_pattern_raises_with_id_and_pattern(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            registry_path = Path(tmpdir) / "registry.yaml"
            registry_path.write_text(self.BAD_REGISTRY_YAML)

            with self.assertRaises(ValueError) as ctx:
                _parse_registry(registry_path)

            msg = str(ctx.exception)
            self.assertIn("bad-pattern-counter", msg)
            self.assertIn("unclosed_paren(", msg)


if __name__ == "__main__":
    unittest.main()
