"""Config dataclass — all tunables in one place."""
from __future__ import annotations

import datetime
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class Config:
    """Runtime configuration for the analyzer."""

    since: datetime.date
    as_json: bool = False
    window: int = 2
    reread_threshold: int = 2
    project_dir: Optional[Path] = None
    claude_projects_root: Path = field(
        default_factory=lambda: Path.home() / ".claude" / "projects"
    )
    codegen_dir: Path = field(default_factory=lambda: Path(os.getcwd()))
