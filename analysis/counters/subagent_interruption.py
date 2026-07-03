"""Counter (repo-level): scan session logs for subagent-death thrash markers."""
from __future__ import annotations

from pathlib import Path
from typing import List, Tuple

from analysis.config import Config
from analysis.counters import Finding

# marker prefix -> (pattern_key, wasted_turns)
# interrupted: drop+respawn = 2; aborted: drop-twice+halt = 3; resumed: recovery = 0.
_MARKERS: List[Tuple[str, str, int]] = [
    ("### INTERRUPTED ⚠️", "interrupted", 2),
    ("### RESUMED", "resumed", 0),
    ("### ABORTED \U0001f480", "aborted", 3),
]


def run_repo(config: Config) -> List[Finding]:
    """Scan <logging_dir>/*_session.md for the three thrash markers.

    Repo-level (NOT per-session) so markers are counted once, not once per
    transcript.  Returns [] gracefully when the logging dir is absent.
    """
    logging_dir = _logging_dir(config)
    if not logging_dir.exists():
        return []

    findings: List[Finding] = []
    for log_path in sorted(logging_dir.glob("*_session.md")):
        try:
            text = log_path.read_text(encoding="utf-8")
        except OSError:
            continue
        session_id = log_path.name
        for lineno, line in enumerate(text.splitlines(), start=1):
            for prefix, pattern_key, wasted in _MARKERS:
                if line.startswith(prefix):
                    findings.append(
                        Finding(
                            counter="subagent_interruption",
                            pattern_key=pattern_key,
                            session_id=session_id,
                            turn_index=lineno,
                            wasted_turns=wasted,
                            evidence=line,
                        )
                    )
                    break  # one marker per line
    return findings


def _logging_dir(config: Config) -> Path:
    """Resolve session-log dir: project_dir (test) or codegen_dir/codegen/logging.

    Mirrors hook_intervention._substrate_root so the test seam is identical.
    """
    if config.project_dir is not None:
        return Path(config.project_dir)
    return config.codegen_dir / "codegen" / "logging"
