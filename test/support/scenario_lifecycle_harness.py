#!/usr/bin/env python3
"""Controlled offline provider for scenario-tracking lifecycle fixtures."""
import json
import os
import pathlib
import subprocess
import sys

MARKER = "KOGEN_TASK_CONTEXT"
LEGACY_MARKER = "KOGEN_TRACKING_CONTEXT"
ROOT = pathlib.Path.cwd()
RUNTIME = ROOT / ".kogen/runtime"


def context(prompt):
    lines = prompt.splitlines()
    snapshots = []
    for index, line in enumerate(lines[:-1]):
        if line in (MARKER, LEGACY_MARKER):
            try:
                snapshots.append(json.loads(lines[index + 1]))
            except json.JSONDecodeError:
                pass
    value = snapshots[-1] if snapshots else {}
    path = value.get("tracking_path")
    if path:
        try:
            record = json.loads(pathlib.Path(path).read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"unreadable tracking record: {path}") from error
        attempts = record.get("attempts", [])
        attempt = attempts[-1] if attempts else {}
        if value.get("attempt_token") != attempt.get("attempt_token"):
            raise ValueError("task context attempt token does not match current record attempt")
        if value.get("candidate_id") and value["candidate_id"] != attempt.get("candidate_id"):
            raise ValueError("task context candidate does not match current record attempt")
        value = {**value, **record}
        value["open_findings"] = [f for f in record.get("findings", []) if f.get("status") == "open"]
        value["attempt"] = attempt
    return value


def refs():
    return [{"path": "Makefile", "locator": "check"}]


def count(name):
    path = RUNTIME / name
    value = int(path.read_text()) if path.exists() else 0
    path.write_text(str(value + 1))
    return value + 1


def developer(snapshot, call, mode):
    response = {
        "attempt_token": snapshot.get("attempt_token", "missing-token"),
        "scenarios": [
            {"id": item["id"], "status": "ready", "claim": item["then"], "implementation": refs(), "evidence": refs()}
            for item in snapshot.get("scenarios", [])
        ],
        "risks": [
            {"id": item["id"], "scenario_ids": item["scenario_ids"], "response": "fixture risk response", "evidence": refs()}
            for item in snapshot.get("risks", [])
        ],
        "findings": [
            {"id": item["id"], "status": "disputed" if mode == "partial_dispute" else "addressed", "response": "fixture response", "evidence": refs()}
            for item in snapshot.get("open_findings", [])
        ],
    }
    if call == 1:
        if mode == "handoff_missing": return {}
        if mode == "handoff_stale": response["attempt_token"] = "stale-token"
        if mode == "handoff_incomplete": response["scenarios"] = []
        if mode == "handoff_duplicate": response["scenarios"] += response["scenarios"][:1]
        if mode == "handoff_unknown" and response["scenarios"]: response["scenarios"][0]["id"] = "unknown"
    return response


def verdict(snapshot, review, mode):
    ids = [item["id"] for item in snapshot.get("scenarios", [])]
    open_ids = [item["id"] for item in snapshot.get("open_findings", [])]
    rework = mode in {"exhaust", "target_history"} or (mode == "partial_dispute" and review < 3) or (mode == "regression" and review < 3) or (mode in {"review_evidence", "omitted_disposition", "record_citations"} and review == 1)
    status = "needs_rework" if rework else "satisfied"
    dispositions = [
        {"id": finding, "status": "open" if rework else "closed", "reason": "fixture disposition", "evidence": refs()}
        for finding in open_ids
    ]
    findings = []
    if rework and not open_ids:
        count_new = 2 if mode in {"target_history", "partial_dispute"} and review == 1 else 1
        findings = [{"scenario_ids": ids, "reason": f"fixture finding {index}", "evidence": refs()} for index in range(1, count_new + 1)]
    if mode == "partial_dispute" and review == 2 and dispositions:
        dispositions[0]["status"] = "open"
        for item in dispositions[1:]: item["status"] = "closed"
    if mode == "regression" and review == 2:
        dispositions = [{"id": finding, "status": "closed", "reason": "fixed", "evidence": refs()} for finding in open_ids]
        findings = [{"scenario_ids": ids, "reason": "regression found", "evidence": refs()}]
    return {
        "candidate_id": snapshot.get("candidate_id", "missing-candidate"),
        "attempt_token": snapshot.get("attempt_token", "missing-token"),
        "verdict": "rework" if rework else "accept",
        "scenarios": [{"id": scenario, "status": status, "reason": "fixture review", "evidence": refs()} for scenario in ids],
        "dispositions": dispositions,
        "findings": findings,
    }


def main():
    RUNTIME.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]
    prompt = sys.stdin.read()
    mode = os.environ.get("SCENARIO_LIFECYCLE_MODE", "accept")
    reviewer = "--output-schema" in args
    resume = "resume" in args
    if reviewer:
        output = args[args.index("--output-last-message") + 1]
        snapshot = context(prompt)
        review_number = count("reviews")
        response = verdict(snapshot, review_number, mode)
        if mode == "review_evidence" and review_number == 1:
            proof = RUNTIME / "review-proof.txt"
            proof.write_text("independently inspected first-candidate evidence")
            response["findings"][0]["evidence"] = [{"path": ".kogen/runtime/review-proof.txt", "locator": "line 1"}]
        if mode == "omitted_disposition" and review_number == 2:
            response["dispositions"] = []
        if mode in {"record_citations", "record_citation_tamper"}:
            record = next((RUNTIME / "scenario-tracking").glob("*/record.json"))
            (RUNTIME / f"reviewer-inspected-{review_number}.json").write_bytes(record.read_bytes())
            response["scenarios"][0]["evidence"].append({"path": str(record.relative_to(ROOT)), "locator": "current attempt Check receipt"})
            if mode == "record_citation_tamper":
                record.write_text(record.read_text() + " tampered by Reviewer")
        pathlib.Path(output).write_text(json.dumps(response))
        review = (RUNTIME / "reviews").read_text()
        print(json.dumps({"type": "thread.started", "thread_id": f"review-{review}"}))
        print(json.dumps({"type": "turn.completed", "thread_id": f"review-{review}"}))
        return
    call = count("developer-calls")
    if resume:
        (RUNTIME / "resume-sessions").open("a").write(args[-2] + "\n")
        if mode == "target_history" and call == 2: (RUNTIME / "fail-target").touch()
        else: (RUNTIME / "fail-target").unlink(missing_ok=True)
        if mode == "regression": (ROOT / "dummy.txt").write_text(f"candidate {call}\n")
        if mode == "review_evidence": (RUNTIME / "review-proof.txt").unlink(missing_ok=True)
    subprocess.run(["sh", ".codex/hooks/check.sh"], input=b'{"session_id":"developer-session"}', check=True)
    response = developer(context(prompt), call, mode)
    if mode == "record_citations":
        record = next((RUNTIME / "scenario-tracking").glob("*/record.json"))
        (RUNTIME / f"developer-inspected-{call}.json").write_bytes(record.read_bytes())
        response["scenarios"][0]["evidence"].append({"path": str(record.relative_to(ROOT)), "locator": "Build supplied attempt state"})
    if mode == "record_mutation":
        records = list((RUNTIME / "scenario-tracking").glob("*/record.json"))
        if records: records[0].write_text(records[0].read_text() + " tampered")
    print(json.dumps({"type": "thread.started", "thread_id": "developer-session"}))
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(response)}}))
    print(json.dumps({"type": "turn.completed", "thread_id": "developer-session"}))


if __name__ == "__main__":
    main()
