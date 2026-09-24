#!/usr/bin/env python3
"""Validate native UI bookkeeping without importing configuration or credentials.

Codex may persist these settings after interactive use. Unknown configuration
is refused, not deleted or adopted. The only returned data is project paths so
an invocation can override retained trust without rewriting a shared file.
"""
import json
import os
import stat
import sys

try:
    import tomllib
except ImportError:
    tomllib = None


def project_paths(path):
    flags = os.O_RDONLY | os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return []
    with os.fdopen(descriptor, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("nonregular configuration")
        data = tomllib.load(source)
    if set(data) - {"projects", "tui"}:
        raise ValueError("unrecognized configuration")
    projects = data.get("projects", {})
    if not isinstance(projects, dict):
        raise ValueError("invalid project bookkeeping")
    for path, settings in projects.items():
        if not os.path.isabs(path) or os.path.normpath(path) != path:
            raise ValueError("invalid project path")
        if (not isinstance(settings, dict) or set(settings) != {"trust_level"}
                or settings["trust_level"] not in ("trusted", "untrusted")):
            raise ValueError("invalid project trust bookkeeping")
    tui = data.get("tui", {})
    # Native 0.156.1 records that its one-time screen reader probe ran.
    if not isinstance(tui, dict) or set(tui) - {"model_availability_nux", "screen_reader_detection_done"}:
        raise ValueError("unrecognized UI configuration")
    if type(tui.get("screen_reader_detection_done", True)) is not bool:
        raise ValueError("invalid UI bookkeeping")
    nux = tui.get("model_availability_nux", {})
    if not isinstance(nux, dict) or any(
            not name.strip() or type(value) is not int for name, value in nux.items()):
        raise ValueError("invalid UI bookkeeping")
    return sorted(projects)


if __name__ == "__main__":
    if sys.version_info < (3, 11) or tomllib is None:
        print("Kogen Codex native settings requires Python 3.11+ (tomllib unavailable)", file=sys.stderr)
        sys.exit(2)
    try:
        print(json.dumps(project_paths(sys.argv[1])))
    except (OSError, ValueError):
        # Do not echo TOML parser exceptions: they can contain setting values.
        print("Unrecognized native bookkeeping configuration", file=sys.stderr)
        sys.exit(1)
