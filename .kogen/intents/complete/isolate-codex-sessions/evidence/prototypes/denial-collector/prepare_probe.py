"""Create an Intent-local disposable workspace; never modify source checkout files."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys

base = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve()
workspace = base / "workspace"
expected = {
    "lib/kogen/codex/compatibility.ex": "31e2c5f382f8d2a375a71a8446b34ba066ceac48c77364e3f8b829e7c1c26802",
    "priv/kogen/codex/compatibility/bounded_exec.py": "0e37e03fc37f291df01d58d4babab02b6fc20a1624b00d03c138c89e2824b73a",
}
for name, digest in expected.items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
        raise SystemExit("Source changed; reassess prototype before applying: " + name)
workspace.mkdir(exist_ok=False)
for name in ["lib", "priv", "test", "scripts", ".codex", "deps"]:
    if (source / name).exists():
        shutil.copytree(source / name, workspace / name,
                        ignore=shutil.ignore_patterns("__pycache__", ".git"))
for name in ["mix.exs", "mix.lock", "Makefile", "README.md", ".formatter.exs", ".gitignore", "mise.toml"]:
    if (source / name).exists():
        shutil.copy2(source / name, workspace / name)
(workspace / ".kogen").mkdir()
shutil.copy2(source / ".kogen/config.yaml", workspace / ".kogen/config.yaml")
for name in [*expected, "test/kogen/codex_denial_evidence_test.exs", "test/prototype_live_test.exs"]:
    shutil.copy2(base / name, workspace / name)
subprocess.run(["git", "init", "-q", str(workspace)], check=True)
print(workspace)
