#!/usr/bin/env python3
"""Build structured fake-provider responses from the last tracking snapshot.

The fixture providers deliberately share this small parser so an old tracking
block earlier in a rendered prompt cannot accidentally satisfy a new attempt.
"""
import json
import sys

MARKER = "KOGEN_TRACKING_CONTEXT"


def snapshot(prompt):
    lines = prompt.splitlines()
    values = []
    for index, line in enumerate(lines[:-1]):
        if line == MARKER:
            try:
                values.append(json.loads(lines[index + 1]))
            except json.JSONDecodeError:
                pass
    return values[-1] if values else {}


def evidence(path="Makefile", locator="check"):
    return [{"path": path, "locator": locator}]


def developer(context):
    scenarios = context.get("scenarios", [])
    risks = context.get("risks", [])
    open_findings = context.get("open_findings", [])
    return {
        "attempt_token": context.get("attempt_token", "fixture-attempt"),
        "scenarios": [
            {
                "id": item.get("id", "fixture-scenario"),
                "status": "ready",
                "claim": item.get("then", "fixture implementation is ready"),
                "implementation": evidence(),
                "evidence": evidence(),
            }
            for item in scenarios
        ],
        "risks": [
            {
                "id": item["id"],
                "scenario_ids": item["scenario_ids"],
                "response": "fixture risk reviewed",
                "evidence": evidence(),
            }
            for item in risks
        ],
        "findings": [
            {
                "id": item["id"],
                "status": "addressed",
                "response": "fixture finding addressed",
                "evidence": evidence(),
            }
            for item in open_findings
        ],
    }


def reviewer(context, verdict, finding_id=None):
    scenarios = context.get("scenarios", [])
    candidate_id = context.get("candidate_id", "fixture-candidate")
    token = context.get("attempt_token", "fixture-attempt")
    rework = verdict == "rework"
    ids = [item.get("id", "fixture-scenario") for item in scenarios]
    scenario_entries = [
        {
            "id": scenario_id,
            "status": "needs_rework" if rework else "satisfied",
            "reason": "fixture review requires a correction" if rework else "fixture review verified the candidate",
            "evidence": evidence(),
        }
        for scenario_id in ids
    ]
    findings = (
        [{"scenario_ids": ids or ["fixture-scenario"], "reason": "fixture rework", "evidence": evidence()}]
        if rework
        else []
    )
    dispositions = [
        {
            "id": item["id"],
            "status": "open" if rework else "closed",
            "reason": "fixture finding remains" if rework else "fixture finding is addressed",
            "evidence": evidence(),
        }
        for item in context.get("open_findings", [])
    ]
    if finding_id and not dispositions:
        dispositions = [
            {
                "id": finding_id,
                "status": "open" if rework else "closed",
                "reason": "fixture finding remains" if rework else "fixture finding is addressed",
                "evidence": evidence(),
            }
        ]
    return {
        "candidate_id": candidate_id,
        "attempt_token": token,
        "verdict": verdict,
        "scenarios": scenario_entries,
        "dispositions": dispositions,
        "findings": findings,
    }


def main():
    mode = sys.argv[1]
    prompt = sys.stdin.read()
    context = snapshot(prompt)
    if mode == "developer":
        response = developer(context)
    elif mode == "reviewer":
        response = reviewer(context, sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        raise SystemExit("usage: scenario_response.py developer|reviewer accept|rework [finding-id]")
    print(json.dumps(response, separators=(",", ":")))


if __name__ == "__main__":
    main()
