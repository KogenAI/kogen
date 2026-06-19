"""Counter: detect Bash tool_uses matching universal denial patterns from registry.yaml."""
from __future__ import annotations

import re
from pathlib import Path
from typing import List, Optional, Tuple


def _unescape_yaml_double_quoted(val: str) -> str:
    """Decode YAML double-quoted scalar escape sequences.

    YAML stores regex patterns in double-quoted scalars where \\\\ → \\ and \\s → \\s.
    Python's read_text() returns raw bytes, so we must decode YAML escapes before
    passing to re.search().  Only handles the subset used in registry patterns.
    """
    return val.encode("latin-1").decode("unicode_escape")

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session
from analysis.turn_window import evidence_snippet


def _parse_registry(registry_path: Path) -> List[Tuple[str, List[str]]]:
    """Parse registry.yaml with stdlib (no yaml module) to extract universal Bash denials.

    Returns list of (id, [regex_pattern, ...]) tuples.
    Selects entries where:
      - tool_guard: Bash
      - role: "*"
      - kind absent OR not 'allowlist'
      - mode absent OR not 'allowlist'
    """
    if not registry_path.exists():
        return []

    try:
        text = registry_path.read_text(encoding="utf-8")
    except OSError:
        return []

    results: List[Tuple[str, List[str]]] = []

    # Split on YAML list entries (lines starting with "- id:")
    entries = []
    current: List[str] = []
    for line in text.splitlines():
        if line.startswith("- id:"):
            if current:
                entries.append(current)
            current = [line]
        elif current:
            current.append(line)
    if current:
        entries.append(current)

    for entry_lines in entries:
        entry_text = "\n".join(entry_lines)

        # Extract fields
        entry_id: Optional[str] = None
        tool_guard: Optional[str] = None
        role: Optional[str] = None
        mode: Optional[str] = None
        kind: Optional[str] = None
        match_single: Optional[str] = None
        match_all: List[str] = []

        in_match_all = False
        for line in entry_lines:
            stripped = line.strip()
            # First line of entry is "- id: <value>"; subsequent id lines are "id: <value>"
            if stripped.startswith("- id:"):
                entry_id = stripped[5:].strip()
                in_match_all = False
            elif stripped.startswith("id:"):
                entry_id = stripped[3:].strip()
                in_match_all = False
            elif stripped.startswith("tool_guard:"):
                tool_guard = stripped[11:].strip()
                in_match_all = False
            elif stripped.startswith("role:"):
                role = stripped[5:].strip().strip('"')
                in_match_all = False
            elif stripped.startswith("mode:"):
                mode = stripped[5:].strip()
                in_match_all = False
            elif stripped.startswith("kind:"):
                kind = stripped[5:].strip()
                in_match_all = False
            elif stripped.startswith("match_all:"):
                in_match_all = True
                match_single = None
            elif stripped.startswith("match:") and not stripped.startswith("match_all:"):
                in_match_all = False
                val = stripped[6:].strip()
                # Strip surrounding quotes and decode YAML escapes
                if val.startswith('"') and val.endswith('"'):
                    val = _unescape_yaml_double_quoted(val[1:-1])
                elif val.startswith("'") and val.endswith("'"):
                    val = val[1:-1]
                match_single = val
            elif in_match_all and stripped.startswith("- "):
                val = stripped[2:].strip()
                if val.startswith('"') and val.endswith('"'):
                    val = _unescape_yaml_double_quoted(val[1:-1])
                elif val.startswith("'") and val.endswith("'"):
                    val = val[1:-1]
                match_all.append(val)
            elif not stripped.startswith("-") and stripped:
                # Non-list-item line while in match_all resets it
                if in_match_all and not stripped.startswith("- "):
                    in_match_all = False

        # Apply filters
        if entry_id is None:
            continue
        if tool_guard != "Bash":
            continue
        if role != '"*"' and role != "*":
            continue
        if mode == "allowlist":
            continue
        if kind == "allowlist":
            continue

        patterns: List[str] = []
        if match_single:
            patterns = [match_single]
        elif match_all:
            patterns = match_all

        if patterns:
            results.append((entry_id, patterns))

    return results


def _matches_denial(command: str, patterns: List[str]) -> bool:
    """Return True if command matches ALL patterns in the list (AND logic for match_all)."""
    for pat in patterns:
        # Registry uses \s (Python-native); compile directly
        try:
            if not re.search(pat, command):
                return False
        except re.error:
            return False
    return True


def run(session: Session, config: Config) -> List[Finding]:
    """Find Bash tool_uses that match universal denial patterns."""
    registry_path = config.codegen_dir / "shared" / "enforcement" / "registry.yaml"
    denials = _parse_registry(registry_path)
    if not denials:
        return []

    findings: List[Finding] = []
    for turn in session.turns:
        for tu in turn.tool_uses:
            if tu.name != "Bash" or not tu.command:
                continue
            for denial_id, patterns in denials:
                if _matches_denial(tu.command, patterns):
                    evidence = evidence_snippet(session.turns, turn.index, config.window)
                    findings.append(
                        Finding(
                            counter="forbidden_bash",
                            pattern_key=denial_id,
                            session_id=session.session_id,
                            turn_index=turn.index,
                            wasted_turns=2,  # blocked + retry = 2 turns wasted
                            evidence=evidence,
                        )
                    )
                    break  # one finding per tool_use (first matching denial)
    return findings
