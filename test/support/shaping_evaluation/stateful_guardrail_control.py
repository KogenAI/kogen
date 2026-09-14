#!/usr/bin/env python3
"""Deterministic controls for both stateful guardrail proposals."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "stateful_guardrail.py"


def run(mode):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        def fixture(name):
            directory = root / name; directory.mkdir()
            state, action, receipt = (directory / item for item in ("state.json", "action.json", "receipt.json"))
            state.write_text(json.dumps({"version": 1, "failures": 0, "history": []}))
            action.write_text('{"count": 0}\n')
            command = ["python3", "-B", str(SOURCE), mode, str(state), str(action), str(receipt)]
            return state, action, receipt, command

        state, action, receipt, command = fixture("corruption")
        first = subprocess.run(command, capture_output=True, text=True)
        second = subprocess.run(command, capture_output=True, text=True)
        state.write_text("not-json\n")
        corrupted = subprocess.run(command, capture_output=True, text=True)

        exhausted_state, exhausted_action, _exhausted_receipt, exhausted_command = fixture("exhaustion")
        exhausted_state.write_text(json.dumps({"version": 1, "failures": 3, "history": [{"result": "failed", "failures": 1}, {"result": "failed", "failures": 2}, {"result": "failed", "failures": 3}]}))
        exhausted = subprocess.run(exhausted_command, capture_output=True, text=True)

        _repair_state, repair_action, repair_receipt, repair_command = fixture("repair")
        subprocess.run(repair_command, capture_output=True, text=True)
        repair = subprocess.run(repair_command + ["--passed"], capture_output=True, text=True)
        consumed = subprocess.run(repair_command + ["--consume"], capture_output=True, text=True)
        return {
            "mode": mode, "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "commands": [command, repair_command + ["--passed"], repair_command + ["--consume"]],
            "cycles": [json.loads(first.stdout), json.loads(second.stdout)],
            "corrupt_state": json.loads(corrupted.stdout), "exhausted_replay": json.loads(exhausted.stdout),
            "repair": json.loads(repair.stdout), "receipt_consumer": json.loads(consumed.stdout),
            "action_count": sum(json.loads(path.read_text())["count"] for path in (action, exhausted_action, repair_action)),
            "limitations": "Deterministic local source controls prove fixture behavior, not provider access or application correctness."
        }


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("mode", choices=("flawed", "complete")); parser.add_argument("--output", type=Path)
    args = parser.parse_args(); result = run(args.mode); data = json.dumps(result, indent=2) + "\n"
    if args.output: args.output.write_text(data)
    print(data, end="")


if __name__ == "__main__": main()
