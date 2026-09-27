#!/usr/bin/env python3
"""Calibrate `question-gate-v1` (use 12): technical / product_ux / already_settled,
plus `settled-by` (Choice over decision ids + none). Shaping continuation 2026-09-25.

Changes against finding-routing-v1: splitting or deferring requested scope is
product_ux (DIRECTION 1.17), and an item already answered by a listed decision
is already_settled. State per item: the item and the settled-decision list.
Only item text and the short decision paraphrases below are sent.
"""
import json, os, subprocess, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import calibrate as v1

HERE = Path(__file__).parent
MODEL = "jev-1.13.0"
KEY = subprocess.check_output(["security", "find-generic-password", "-s", "dev.kogen.jev", "-w"], text=True).strip()

SETTLED = [
    {"id": "dir-1.7", "text": "Hooks, tools and logging move to Rust eventually; starting Elixir in hooks is too slow."},
    {"id": "dir-1.11-live", "text": "Live (paid) checks are chosen deliberately, never by default, and an edited live test always runs in the same Intent."},
    {"id": "dir-1.12", "text": "Plans live in the iCloud Kogen plan folder, not in .kogen/runtime/shaping-followups."},
    {"id": "dir-1.13", "text": "Plain Kogen always requires explicit human approval of each Intent; only Kogen Studio may approve on the human's behalf."},
    {"id": "dir-1.15", "text": "Use slugs, not numeric ids, to refer to Intents."},
    {"id": "dir-1.16", "text": "Never add plumbing (function, config key, role, option) whose caller comes in a later Intent; wire it in the same Intent."},
    {"id": "dir-1.17", "text": "Never split or defer requested scope to another Intent on the agent's own judgement, and never to avoid paid checks; a necessary split is the human's decision."},
    {"id": "shp-auditor-profile", "text": "The Shaping auditor runs on the adversarial harness on hybrid routes; on Codex it is GPT-6 Sol at high effort, on Claude it is Opus at high effort."},
    {"id": "shp-one-build", "text": "The Shaping audit (deterministic checks, Jev, auditor, Stop hook, Build gate) is one Intent and one Build."},
    {"id": "shp-wait-only-product", "text": "The Shaping audit reshapes automatically and waits for the human only on UI/UX/product decisions."},
]

GATE = {
    "type": "choice",
    "instructions": {
        "task": "Who must answer item `item`, raised while shaping one software feature contract, given the decisions in `settled`?",
        "rules": [
            "already_settled: a decision in `settled` already answers exactly what the item asks; the agent cites it and nobody is asked.",
            "product_ux: what the product does or shows for its users or developers (behaviour, output, workflow, commands they run, defaults they see), which features or platforms are in or out, splitting or deferring any requested scope to another Intent or Build, which models, vendors or spending to use, and who may approve or act.",
            "technical: how to build and prove the requested scope: code structure, modules, file locations, formats, limits, parsing, tests and proofs, severities and thresholds of internal checks, and fixing a defect or gap in the contract.",
            "Judge the decision the item asks for, not how technical its wording is. A decision that is only related, or merely on the same topic, is not already_settled.",
        ],
    },
    "criteria": {
        "technical": "How to build or prove it; the agent settles it.",
        "product_ux": "What users or developers get, scope and splits, vendors, spending or authority; the human decides.",
        "already_settled": "A listed decision already answers it.",
    },
}

def settled_by():
    return {
        "type": "choice",
        "instructions": {"task": "Which decision in `settled` directly answers item `item`? Choose none if no decision answers exactly what it asks."},
        "criteria": {**{d["id"]: d["text"] for d in SETTLED}, "none": "No listed decision answers it."},
    }

# Relabel from v1 per DIRECTION 1.17 (splits are product), and new items.
RELABEL = {"Scope exceeds one Build: the Draft combines a 14-entry question engine, Noul parsing, batching, citation extraction and docs. Split it or add checkpoints.": "P"}
NEW = [
    ("S:dir-1.17", "new", "Should the default-route flip move to a follow-up Intent so this Build does not need two more paid targets?"),
    ("S:dir-1.16", "new", "Should this Intent add launch_auditor/4 now and let the Shaping-audit Intent add its caller later?"),
    ("S:dir-1.13", "new", "Should plain Kogen approve an Intent automatically when its audit report is ready?"),
    ("S:dir-1.12", "new", "Should the new planning notes be written under .kogen/runtime/shaping-followups?"),
    ("S:dir-1.15", "new", "Should the roadmap refer to this Intent as number 3 or by its slug?"),
    ("S:dir-1.11-live", "new", "Should the edited live test be skipped in this Build because it costs money?"),
    ("S:shp-auditor-profile", "new", "Which model and effort should the auditor use on the codex route?"),
    ("S:shp-one-build", "new", "Should the Jev layer of the Shaping audit ship as a separate Build after the deterministic checks?"),
    ("S:shp-wait-only-product", "new", "Should the Stop hook wait for the Shaper whenever the report is not ready?"),
    ("P", "new", "Should Kogen defer the paid-target health reader to a later Intent to keep this Build small?"),
    ("P", "new", "Should the audit report be shown in a web dashboard?"),
    ("T", "new", "Should the auditor's model come from the route's Expert entry or from a new auditor key, given both hold the same profile on every configured route?"),
    ("T", "new", "The Stop hook reason must stay under 16 KiB; truncate the advisory list first."),
    ("T", "new", "Should the sibling-Intent check read approved packages from HEAD or from the working tree?"),
    ("T", "new", "Should hook-state.json count blocks per session id or per process?"),
]

def items():
    base = [(RELABEL.get(t, l), s, t) for l, s, t in v1.ITEMS + v1.HELDOUT]
    return base + NEW

def ask(i, item):
    body = json.dumps({"model": MODEL, "state": {"item": item, "settled": SETTLED},
                       "questions": {"gate": GATE, "by": settled_by()}}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", data=body,
                                 headers={"authorization": "Bearer " + KEY, "content-type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return {"i": i, "response": json.loads(r.read())}
        except Exception as e:
            err = repr(e); time.sleep(2 * (attempt + 1))
    return {"i": i, "error": err}

def main():
    its = items()
    with ThreadPoolExecutor(8) as pool:
        out = list(pool.map(lambda p: ask(*p), enumerate(t for _, _, t in its)))
    tag = os.environ.get("TAG", "v3")
    (HERE / f"raw-gate-{tag}.json").write_text(json.dumps({"settled": SETTLED, "gate": GATE, "results": out}, indent=1))
    rows = []
    lines = ["| # | label | choice | P(prod) | P(settled) | by | by_p |", "|---|---|---|---|---|---|---|"]
    for (label, src, text), r in zip(its, out):
        if "error" in r:
            lines.append(f"| {r['i']} | {label} | ERROR {r['error']} |"); continue
        g = r["response"]["answers"]["gate"]; b = r["response"]["answers"]["by"]
        pp = g["probabilities"].get("product_ux", 0); ps = g["probabilities"].get("already_settled", 0)
        rows.append((label, g["choice"], pp, ps, b["choice"], b.get("confidence", 0)))
        lines.append(f"| {r['i']} | {label} | {g['choice']} | {pp:.2f} | {ps:.2f} | {b['choice']} | {b.get('confidence',0):.2f} |")
    def stat(gp, gs, gb):
        res = {"P->shaper": 0, "P": 0, "T->shaper": 0, "T": 0, "S->cited_ok": 0, "S->shaper": 0, "S": 0, "wrong_cite": 0}
        for label, ch, pp, ps, by, bp in rows:
            cite = ps >= gs and by != "none" and bp >= gb
            shaper = (not cite) and pp >= gp
            k = label[0]
            res[k] += 1
            if k == "P": res["P->shaper"] += shaper
            if k == "T": res["T->shaper"] += shaper
            if k == "S":
                res["S->cited_ok"] += cite and by == label[2:]
                res["S->shaper"] += shaper
            if cite and (k != "S" or by != label[2:]): res["wrong_cite"] += 1
        return res
    for gp in (0.5, 0.6):
        for gs in (0.6, 0.8):
            for gb in (0.6, 0.8):
                lines.append(f"\nproduct>={gp} settled>={gs} by>={gb}: {stat(gp, gs, gb)}")
    (HERE / f"summary-gate-{tag}.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[-10:]))

if __name__ == "__main__":
    main()
