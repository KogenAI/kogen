#!/usr/bin/env python3
"""Calibrate the `finding-routing` Choice (technical / product_ux) on labelled items.

Items are real questions.md decisions (Shaper-owned vs controller-owned, per their
recorded provenance), real Sol/Astra findings, and a few written product/UX questions.
Sends only the item text. Writes raw.json and summary.md next to this file.
"""
import json, subprocess, time, urllib.request, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).parent
MODEL = "jev-1.13.0"
KEY = subprocess.check_output(["security", "find-generic-password", "-s", "dev.kogen.jev", "-w"], text=True).strip()

QUESTION = {
    "type": "choice",
    "instructions": {
        "task": "Who must decide item `item`, raised while shaping one software feature contract?",
        "rules": [
            "product_ux: what the product does or shows for its users or developers (behaviour, output, workflow, commands they run, defaults they see), which features or platforms are in or out, which models, vendors or spending to use, and who may approve or act.",
            "technical: how to build and prove it: code structure, modules, file locations, formats, limits, parsing, tests and proofs, severities and thresholds of internal checks, fixing a defect or gap in the contract, and splitting work into Builds.",
            "Judge the decision the item asks for, not how technical its wording is.",
        ],
    },
    "criteria": {
        "technical": "How to build or prove it; the agent settles it.",
        "product_ux": "What users or developers get, scope, vendors, spending or authority; the human decides.",
    },
}

# label: T = technical, P = product_ux. Source noted per item.
ITEMS = [
    # Shaper-decided (named-routes, claude-code-harness questions.md)
    ("P", "named-routes", "Old flat config: should Kogen refuse an old flat-shape config, warn and migrate it, or keep a compatibility reader?"),
    ("P", "named-routes", "Route names: should this repository's routes be named after their harness (claude, codex) or after the vendor (chatgpt)?"),
    ("P", "claude-code-harness", "Should Kogen drive development with Claude Code and Opus 5.5 for the next few days and switch to ChatGPT later, keeping Codex as an adapter?"),
    ("P", "claude-code-harness", "Should Opus 5.5 run at medium effort for shaping, developer and reviewer, with only the expert at high?"),
    ("P", "claude-code-harness", "Should every Kogen claude invocation use --dangerously-skip-permissions, including interactive Shaping and login?"),
    ("P", "claude-code-harness", "Is Haiku 4.5 on the proven model list, or is Sonnet 5 at low the scout?"),
    ("P", "shaping-preflight-audit Q1", "Should the Shaping audit run automatically inside every Shaping session, or only when someone runs mix kogen.audit?"),
    ("P", "shaping-preflight-audit Q2", "Should the Shaping audit gate approval, or only advise the Shaper what is approval-ready?"),
    ("P", "DIRECTION D1", "May Kogen Studio approve Intents on the human's behalf when its alignment check passes, or must every Intent be approved by the human?"),
    ("P", "written", "Should a failed Build notify the Shaper by email, by a macOS notification, or only in the status command?"),
    ("P", "written", "Should the CSV normalizer drop rows with missing required columns, or fail the whole file?"),
    ("P", "written", "Should the booking command show times in the organizer's timezone or the viewer's timezone?"),
    ("P", "written", "Is support for Windows hosts in scope for this Intent, or a non-goal?"),
    ("P", "written", "How many paid live checks per Intent are acceptable to spend by default?"),
    ("P", "written", "Should mix kogen.audit print every advisory finding, or only a count with the report path?"),
    # Controller-decided (named-routes 'decided by the controller', 3a/3c settled technical)
    ("T", "named-routes", "Do the harness setup commands (mix kogen.claude.install, login, status) need to know about routes, given that credentials are per harness scope?"),
    ("T", "named-routes", "Should read_draft/1 treat shaping.route as optional so existing Drafts stay valid?"),
    ("T", "shaping-preflight-audit Q6", "Where should the audit report be stored: inside the Draft package, or under .kogen/runtime/shaping-audits/<slug>/<revision>/?"),
    ("T", "shaping-preflight-audit Q7", "Should selector existence and the ledger be read from the HEAD tree or from the working tree?"),
    ("T", "shaping-preflight-audit Q8", "What bound should the paid-target health reader use: the newest 50 records, files at most 32 MiB, the last 10 receipts per target?"),
    ("T", "adversarial-shaping-auditor Q6", "What format should the auditor's findings use, and what are the limits on title and detail length?"),
    ("T", "adversarial-shaping-auditor Q5", "Should the auditor's working directory come from an optional cd in the launch context, or from File.cd/1 in the shared VM?"),
    ("T", "shaping-audit-jev", "Should the audit use a separate Jev answer parser so the Build handoff parser stays byte-for-byte unchanged?"),
    # Sol/Astra findings (technical defects in a contract)
    ("T", "sol 3b #2", "Payload boundary is contradictory: the Draft says Jev receives full INTENT.md and risks.yaml while the research boundary allows only selected scenario fields. Define one allowlisted serializer."),
    ("T", "sol 3b #5", "The audit evidence hard-codes the forbidden Keychain service ai.typesafe.api in jev_audit.py."),
    ("T", "sol 3b #6", "Modifying the fake Jev can weaken cataloged Jev proofs without a ledger guard; add a new audit-only fake instead."),
    ("T", "sol 3b #7", "Response retention can leak the Keychain value; redact the key before retaining any response body."),
    ("T", "sol 3b #9", "The effect of advisory findings on readiness is unspecified; state that findings never block readiness and test it."),
    ("T", "sol 3b #1", "Scope exceeds one Build: the Draft combines a 14-entry question engine, Noul parsing, batching, citation extraction and docs. Split it or add checkpoints."),
    ("T", "sol 3a", "The frozen path list is hardcoded and proven only by comparing it with itself; derive it from a controller function with an independent behavioural control."),
    ("T", "sol 3a", "Stat-before-read is not proven: a reader could read an oversized record before checking its size."),
    ("T", "astra 3a #2", "Make the ledger-consumer-witness finding blocking instead of advisory."),
    ("T", "written", "The scenario selects live-native, but its observation (the record has no inline self copy) is checkable offline."),
    ("T", "written", "The proof selector test/kogen/foo_test.exs does not exist at HEAD and is not in the scenario's affected_paths."),
    ("T", "written", "Should the report's revision hash include file modes as well as paths and bytes?"),
]

HELDOUT = [
    ("P", "held-out", "Should mix kogen.build ask for confirmation before spending on a paid live target, or run it silently?"),
    ("P", "held-out", "Should Kogen keep supporting Codex once Pi is benchmarked, or remove it?"),
    ("P", "held-out", "Should the status command show all repositories on the machine or only the current one?"),
    ("P", "held-out", "Should the audit report be shown to the Shaper in the terminal after every turn, or only when asked?"),
    ("P", "held-out", "Is a one-hour Build acceptable, or should Kogen trade review depth for speed?"),
    ("P", "held-out", "Should the normalize command overwrite OUTPUT when it already exists, refuse, or ask?"),
    ("T", "held-out", "The hook script must restore HOME and XDG variables before running under native Codex; reuse environment.py."),
    ("T", "held-out", "Should the auditor findings be parsed from the last fenced JSON block or the first?"),
    ("T", "held-out", "The scenario's then clause cannot be observed by the named offline test because the test never reads report.json."),
    ("T", "held-out", "Use Task.async_stream with max_concurrency 4 and a 180 second timeout for Jev requests."),
    ("T", "held-out", "Guarded paths do not cover test/support/shaping_audit/fake_auditor, which scenario auditor-layer lists in affected_paths."),
    ("T", "held-out", "Should the revision be a SHA-256 over sorted relative paths and bytes, or over a git tree object?"),
]


def ask(i, item):
    body = json.dumps({"model": MODEL, "state": {"item": item}, "questions": {"r": QUESTION}}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", data=body,
                                 headers={"authorization": "Bearer " + KEY, "content-type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=60) as r:
        resp = json.loads(r.read())
    return {"i": i, "request": json.loads(body), "response": resp, "latency_ms": int((time.time() - t) * 1000)}


def main():
    global ITEMS
    import os
    if os.environ.get("HELDOUT"): ITEMS = HELDOUT
    with ThreadPoolExecutor(8) as pool:
        out = list(pool.map(lambda p: ask(*p), enumerate(item for _, _, item in ITEMS)))
    (HERE / "raw.json").write_text(json.dumps(out, indent=1))
    lines = ["| # | label | source | choice | P(product_ux) | ok@argmax |", "|---|---|---|---|---|---|"]
    rows = []
    for (label, source, item), r in zip(ITEMS, out):
        a = r["response"]["answers"]["r"]
        p = a["probabilities"].get("product_ux", 0.0)
        rows.append((label, p))
        ok = (a["choice"] == "product_ux") == (label == "P")
        lines.append(f"| {r['i']} | {label} | {source} | {a['choice']} | {p:.2f} | {'yes' if ok else 'NO'} |")
    for gate in (0.5, 0.6, 0.7, 0.8):
        tp = sum(1 for l, p in rows if l == "P" and p >= gate)
        fp = sum(1 for l, p in rows if l == "T" and p >= gate)
        fn = sum(1 for l, p in rows if l == "P" and p < gate)
        lines.append(f"\ngate product_ux >= {gate}: product recall {tp}/{tp+fn}, technical routed to Shaper {fp}/{sum(1 for l,_ in rows if l=='T')}")
    (HERE / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
