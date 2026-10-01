"""Offline consumer for a value learned from a failed Check and its citations."""
import re
from pathlib import Path


VALUE = re.compile(r"Required exact content:\s*([A-Za-z0-9._-]+)")


def consume_check_value(check_output, resume_text, citations, audit_package):
    """Return the value only when Check output and materialized citations agree."""
    match = VALUE.search(check_output or "")
    if not match:
        raise ValueError("Check output does not carry the required value")
    value = match.group(1)
    if not isinstance(resume_text, str) or value not in resume_text:
        raise ValueError("resume text does not carry the Check value")
    root = Path(audit_package).resolve()
    if not isinstance(citations, list) or not citations:
        raise ValueError("source citations are missing")
    proved = False
    for citation in citations:
        relative = citation.get("path") if isinstance(citation, dict) else None
        line = citation.get("line") if isinstance(citation, dict) else None
        excerpt = citation.get("excerpt") if isinstance(citation, dict) else None
        path = (root / relative).resolve() if isinstance(relative, str) else root / "missing"
        if (not path.is_relative_to(root) or not path.is_file() or
                not isinstance(line, int) or line < 1 or not isinstance(excerpt, str)):
            raise ValueError("citation path, line, excerpt, or materialized source is invalid")
        lines = path.read_text(encoding="utf-8").splitlines()
        if line > len(lines) or lines[line - 1] != excerpt:
            raise ValueError("citation excerpt does not match its materialized source line")
        proved = proved or value in excerpt
    if not proved:
        raise ValueError("materialized source excerpts do not prove the Check value")
    return value
