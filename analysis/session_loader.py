"""Session loader — single normalization point for Claude JSONL transcripts."""
from __future__ import annotations

import datetime
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, List, Optional

from analysis.config import Config


@dataclass
class ToolUse:
    """Normalized tool invocation from an assistant turn."""

    tool_use_id: str
    name: str
    command: Optional[str] = None
    file_path: Optional[str] = None
    description: Optional[str] = None


@dataclass
class ToolResult:
    """Normalized tool result from a user turn."""

    tool_use_id: str
    is_error: bool
    content: str


@dataclass
class Turn:
    """One normalized transcript line."""

    index: int
    kind: str  # "assistant" | "user" | "system" | other
    timestamp: str
    cwd: str
    tool_uses: List[ToolUse] = field(default_factory=list)
    user_text: Optional[str] = None
    tool_results: List[ToolResult] = field(default_factory=list)


@dataclass
class Session:
    """An ordered sequence of turns from one transcript file."""

    session_id: str
    path: Path
    turns: List[Turn] = field(default_factory=list)


def _cwd_to_slug(cwd: str) -> str:
    """Convert an absolute path to the Claude project-dir slug format.

    Claude derives slug by replacing every '/' and non-alnum char with '-'.
    Example: /Users/alice/project -> -Users-alice-project
    """
    result = []
    for ch in cwd:
        if ch.isalnum():
            result.append(ch)
        else:
            result.append("-")
    return "".join(result)


def _normalize_turn(index: int, record: dict) -> Turn:
    """Extract a normalized Turn from one raw JSONL record."""
    kind = record.get("type", "unknown")
    timestamp = record.get("timestamp", "")
    cwd = record.get("cwd", "")

    tool_uses: List[ToolUse] = []
    tool_results: List[ToolResult] = []
    user_text: Optional[str] = None

    message = record.get("message", {})
    content = message.get("content", None)

    if kind == "assistant" and isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_use":
                inp = item.get("input", {})
                tool_uses.append(
                    ToolUse(
                        tool_use_id=item.get("id", ""),
                        name=item.get("name", ""),
                        command=inp.get("command"),
                        file_path=inp.get("file_path"),
                        description=inp.get("description"),
                    )
                )
    elif kind == "user":
        if isinstance(content, str):
            user_text = content
        elif isinstance(content, list):
            for item in content:
                if isinstance(item, dict):
                    if item.get("type") == "tool_result":
                        raw_content = item.get("content", "")
                        if isinstance(raw_content, list):
                            # Flatten list content to string
                            parts = []
                            for c in raw_content:
                                if isinstance(c, dict):
                                    parts.append(c.get("text", str(c)))
                                else:
                                    parts.append(str(c))
                            raw_content = " ".join(parts)
                        tool_results.append(
                            ToolResult(
                                tool_use_id=item.get("tool_use_id", ""),
                                is_error=bool(item.get("is_error", False)),
                                content=str(raw_content),
                            )
                        )

    return Turn(
        index=index,
        kind=kind,
        timestamp=timestamp,
        cwd=cwd,
        tool_uses=tool_uses,
        user_text=user_text,
        tool_results=tool_results,
    )


def _load_jsonl(path: Path) -> List[Turn]:
    """Load one JSONL file into normalized turns; skip malformed lines."""
    turns: List[Turn] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for index, line in enumerate(fh):
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                turns.append(_normalize_turn(index, record))
    except OSError:
        pass
    return turns


def _session_id_from_path(path: Path) -> str:
    """Derive a session ID from the file path (parent dir name + stem)."""
    return f"{path.parent.name}/{path.stem}"


def _turn_in_window(turn: Turn, since: datetime.date) -> bool:
    """Return True when turn.timestamp parses to a date on/after since.

    Fail-closed: a turn with a missing or unparseable timestamp is treated
    as out-of-window (excluded), never counted as in-window by default.
    """
    if not turn.timestamp:
        return False
    try:
        # ISO-8601 UTC, e.g. "2026-07-07T21:32:52.204Z". Python's
        # fromisoformat rejects a trailing "Z" pre-3.11, so normalize it.
        ts = turn.timestamp.replace("Z", "+00:00")
        turn_date = datetime.datetime.fromisoformat(ts).date()
    except ValueError:
        return False
    return turn_date >= since


def iter_sessions(config: Config) -> Iterator[Session]:
    """Yield Session objects for all matching transcript files.

    If config.project_dir is set, loads *.jsonl directly from that directory
    (used for hermetic tests). Otherwise derives the cwd-slug prefix and globs
    under config.claude_projects_root.
    """
    if config.project_dir is not None:
        project_dir = Path(config.project_dir)
        for jsonl_path in sorted(project_dir.glob("*.jsonl")):
            # Skip substrate files
            name = jsonl_path.name
            if name in ("failures.jsonl", "gate-verdicts.jsonl"):
                continue
            turns = _load_jsonl(jsonl_path)
            turns = [t for t in turns if _turn_in_window(t, config.since)]
            if not turns:
                continue
            session_id = _session_id_from_path(jsonl_path)
            yield Session(session_id=session_id, path=jsonl_path, turns=turns)
        return

    # Production: glob under ~/.claude/projects/<cwd-slug>*/*.jsonl
    cwd = os.getcwd()
    slug = _cwd_to_slug(cwd)
    projects_root = config.claude_projects_root

    if not projects_root.exists():
        return

    for project_dir in sorted(projects_root.iterdir()):
        if not project_dir.is_dir():
            continue
        if not project_dir.name.startswith(slug):
            continue
        for jsonl_path in sorted(project_dir.glob("*.jsonl")):
            turns = _load_jsonl(jsonl_path)
            turns = [t for t in turns if _turn_in_window(t, config.since)]
            if not turns:
                continue
            session_id = _session_id_from_path(jsonl_path)
            yield Session(session_id=session_id, path=jsonl_path, turns=turns)
