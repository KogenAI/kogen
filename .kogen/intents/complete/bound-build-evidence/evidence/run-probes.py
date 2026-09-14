"""Run only in this package; never run a gate or a provider. Refuse reused output paths."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
WORK = HERE / "probe-work"
assert not WORK.exists(), "Use a fresh owned package for another observation."
WORK.mkdir()
source = ROOT / "lib/kogen/build/tracking.ex"
argv = ["elixir", "-pa", str(ROOT / "_build/dev/lib/jason/ebin"), str(HERE / "probe.exs"), str(source), str(WORK / "tracking")]
run = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=60)
receipt = {"argv": argv, "cwd": str(ROOT), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "exit_code": run.returncode, "stdout": run.stdout, "stderr": run.stderr}
(HERE / "tracking-probe.json").write_text(json.dumps(receipt, indent=2) + "\n")
assert run.returncode == 0, "Retain the failed receipt; do not rerun over it."

fixture = WORK / "git"
fixture.mkdir()
commands = []
def git(*args):
    command = ["git", *args]
    result = subprocess.run(command, cwd=fixture, capture_output=True, timeout=20)
    commands.append({"argv": command, "exit_code": result.returncode})
    assert result.returncode == 0, result.stderr.decode()
    return result.stdout

git("init", "-q")
(fixture / ".gitignore").write_text(".kogen/runtime/\n")
(fixture / "source.txt").write_text("small candidate\n")
runtime = fixture / ".kogen/runtime"
runtime.mkdir(parents=True)
(runtime / "raw.bin").write_bytes(b"x" * 4096)
git("add", "-A")
def staged():
    tree = git("write-tree").decode().strip()
    entries = []
    for line in git("ls-tree", "-rlz", tree).split(b"\0"):
        if not line:
            continue
        metadata, path = line.split(b"\t", 1)
        mode, kind, oid, size = metadata.split()
        entries.append({"path": path.decode(), "bytes": int(size)})
    return entries
ordinary = staged()
git("add", "-f", ".kogen/runtime/raw.bin")
forced = staged()
assert all(item["path"] != ".kogen/runtime/raw.bin" for item in ordinary)
assert {"path": ".kogen/runtime/raw.bin", "bytes": 4096} in forced
(HERE / "git-probe.json").write_text(json.dumps({"commands": commands, "ordinary_staged_tree": ordinary, "forced_staged_tree": forced, "conclusion": "Ignore rules alone cannot prevent forced staging; the final Git tree exposes the raw file and its exact uncompressed size.", "limitations": "Owned synthetic Git fixture only. No future Kogen publication implementation is exercised."}, indent=2) + "\n")
shutil.rmtree(WORK)
print("Source-linked tracking and Git controls passed; disposable trees removed; receipts retained.")
