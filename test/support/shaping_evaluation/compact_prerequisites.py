"""Current source-bound standard-library CLI prerequisites; no proposed feature proof."""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(evidence, mode):
    evidence = Path(evidence).resolve()
    cases = []
    def invoke(script, arg, expected):
        argv = [sys.executable, "-B", str(evidence / script), str(arg)]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        assert result.returncode == expected, (argv, result.returncode, result.stderr)
        cases.append({"argv": argv, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
        return result.stdout
    names = ["plain.csv", "bom.csv", "invalid-date.csv", "naive_reader.py", "reader_control.py"] if mode.startswith("csv") else ["calendar_adapter.py", "capability-seed.json"]
    before = {name: digest(evidence / name) for name in names}
    if mode == "csv-flawed":
        invoke("naive_reader.py", evidence / "plain.csv", 0)
    elif mode.startswith("csv"):
        plain = invoke("reader_control.py", evidence / "plain.csv", 0)
        assert invoke("reader_control.py", evidence / "bom.csv", 0) == plain
        invoke("reader_control.py", evidence / "invalid-date.csv", 2)
    else:
        seed = json.loads((evidence / "capability-seed.json").read_text())
        with tempfile.TemporaryDirectory(prefix="kogen-availability-control-") as directory:
            connection = Path(directory) / "connection.json"
            with connection.open("x") as stream:
                json.dump(seed, stream)
            try:
                connection.open("x")
            except FileExistsError:
                pass
            else:
                raise AssertionError("existing connection overwritten")
            assert json.loads(invoke("calendar_adapter.py", connection, 0)) == seed["slots"]
            for change in ({"scopes": []}, {"scopes": "availability.read"}, {"organizer": "wrong"}):
                connection.write_text(json.dumps({**seed, **change}))
                invoke("calendar_adapter.py", connection, 2)
            connection.write_text(json.dumps({**seed, "slots": []}))
            assert json.loads(invoke("calendar_adapter.py", connection, 0)) == []
            connection.write_text("{malformed")
            invoke("calendar_adapter.py", connection, 2)
            connection.unlink()
            invoke("calendar_adapter.py", connection, 2)
    assert before == {name: digest(evidence / name) for name in names}
    return {"executor": "local Python CLI subprocesses", "mode": mode, "source_sha256": before,
            "cases": cases, "controls": "source preservation; availability additionally tests collision refusal and owned cleanup",
            "limits": "Reader/adapter prerequisites only, no normalized export feature or real provider credentials."}


if __name__ == "__main__":
    print(json.dumps(run(Path(__file__).parent, sys.argv[1]), indent=2))
