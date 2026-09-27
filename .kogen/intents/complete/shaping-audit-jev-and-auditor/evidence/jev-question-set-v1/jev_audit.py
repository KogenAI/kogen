#!/usr/bin/env python3
"""Advisory Jev audit of a Kogen Intent package (driver tool, not Kogen code).

Usage: python3 jev_audit.py <package-dir> <out-dir>
Writes <out-dir>/jev-audit.json (every request, response and distribution) and
<out-dir>/jev-audit.md (flags only). Sends Jev only the package's contract text
(scenarios.yaml, INTENT.md Outcome/Non-goals, questions.md, risks.yaml); never
code, a diff, Candidate files or evidence/. Question wording and gates are the
calibrated set in plan/research/jev-shaping-audit.md (v1, 2026-09-25).
Needs the TypeSafe key in the macOS Keychain service `dev.kogen.jev` (Kogen-only; not ChatGPT Work's ai.typesafe.api), and ruby
(for YAML).
"""
import json, os, re, subprocess, sys, time, urllib.request, urllib.error, copy
from concurrent.futures import ThreadPoolExecutor

MODEL = "jev-1.13.0"
VERSION = "shaping-audit-v1"
_key = None


def key():
    global _key
    if _key is None:
        _key = subprocess.check_output(["security", "find-generic-password", "-s", "dev.kogen.jev", "-w"], text=True).strip()
    return _key


LOG = []


def ask(name, state, questions):
    body = json.dumps({"model": MODEL, "state": state, "questions": questions}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", data=body,
                                 headers={"authorization": "Bearer " + key(), "content-type": "application/json"})
    for attempt in range(3):
        try:
            t = time.time()
            with urllib.request.urlopen(req, timeout=60) as r:
                resp = json.loads(r.read())
            LOG.append({"name": name, "state": state, "questions": questions, "response": resp,
                        "latency_ms": int((time.time() - t) * 1000)})
            return resp["answers"]
        except urllib.error.HTTPError as e:
            if e.code in (429, 529) and attempt < 2:
                time.sleep(2 * (attempt + 1)); continue
            raise SystemExit(f"Jev unavailable ({name}): HTTP {e.code}")
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < 1:
                continue
            raise SystemExit(f"Jev unavailable ({name}): {e}")


def yaml_load(path):
    if not os.path.exists(path):
        return None
    return json.loads(subprocess.check_output(
        ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", path]))


norm = lambda t: " ".join(str(t or "").split())


def split_clauses(text):
    return [p.strip() for p in re.split(r"(?<=[.;])\s+(?=[A-Z`])", norm(text)) if len(p.strip()) > 3]


def split_alternatives(text):
    return [p.strip().rstrip(".") for p in re.split(r";\s*(?:or\s+)?|\.\s+(?:Or\s+)?", norm(text)) if len(p.strip()) > 3]


def evidence_items(text):
    return [p.strip() for p in re.split(r";\s*|\.\s+", norm(text)) if len(p.strip()) > 3]


def md_section(md, title_re):
    m = re.search(r"^##\s+(" + title_re + r")[^\n]*\n(.*?)(?=^##\s|\Z)", md, re.M | re.S | re.I)
    return m.group(2) if m else ""


def list_items(section):
    items = re.split(r"^(?:- |\d+\. )", section, flags=re.M)
    items = [norm(i) for i in items[1:] if norm(i)]
    return items or [norm(p) for p in section.split("\n\n") if norm(p)]


def ch(task, rules, criteria):
    return {"type": "choice", "instructions": {"task": task, "rules": rules}, "criteria": criteria}


def nl(instr, t, f):
    return {"type": "noul", "instructions": instr, "criteria": {"true": t, "false": f}}

# ---------------- question set v1 (calibrated 2026-09-25) ----------------

def q_kind(ref):
    return ch(f"Classify clause `{ref}` of the scenario's `then`.",
              ["Judge only the clause text.",
               "A named file, field, value, argument, exit status, message, stop, or presence/absence of something is observable.",
               "Words like better, faster, robust, natural, thorough, wisely, without a stated measure or bound, are not observable."],
              {"observable": "It states a concrete outcome a test or a retained artifact can check (a value, file, field, argument, status, message, stop, or the absence of one).",
               "unobservable": "It states a quality, feeling, intention or improvement with no concrete measure that a test could check.",
               "not_behaviour": "It is a scoping note, a reference to another Intent, or a statement about the contract itself rather than behaviour."})


def q_asserted(ref):
    return ch(f"Does `scenario.evidence` (and `scenario.proof.offline`) describe a test or retained artifact that checks clause `{ref}`?",
              ["Judge only from `evidence` and `proof`; do not assume tests that are not described.",
               "A general phrase such as 'lifecycle tests' covers a clause only if the evidence names the checked thing or an obviously equivalent one."],
              {"asserted": "The evidence names a test or artifact that checks this clause.",
               "partly": "The evidence covers the clause's topic but not the specific outcome it states.",
               "not_described": "Nothing in the evidence checks this clause."})


def q_plaus(ref):
    return ch(f"Is `{ref}` a plausible mistake a competent Developer implementing `scenario` could make?",
              ["A plausible mistake is a realistic wrong or partial implementation of the scenario's behaviour.",
               "Something unrelated to the scenario, absurd, or not actually wrong is not a plausible mistake."],
              {"plausible": "A realistic wrong or partial implementation of this scenario.",
               "implausible": "Unrealistic, unrelated to the scenario, or absurdly destructive.",
               "not_a_mistake": "Describes acceptable or irrelevant behaviour, not a failure of the scenario."})


Q_CAUGHT_NOUL = nl("Would a test or control that `evidence` explicitly describes fail if the implementation behaved as `wrong_behaviour`?",
                   "`evidence` names an assertion, negative control or case that directly checks the thing `wrong_behaviour` gets wrong.",
                   "`evidence` names no assertion or case that checks it; a general or happy-path test does not count.")

HARD = {
    "timeout": nl("Does `clause` raise, extend or newly loosen a timeout, deadline or time limit compared with before?",
                  "A timeout, deadline or time limit becomes longer or looser.",
                  "No time limit becomes longer; keeping or stating an unchanged limit is false."),
    "effort": nl("Does `clause` lower a model's reasoning effort or switch to a weaker model?",
                 "Effort is lowered or a weaker model is chosen.", "No effort or model is lowered."),
    "weaken": nl("Does `clause` remove, loosen or rewrite an existing test assertion, validator or check so that it accepts more?",
                 "An existing assertion, validator or check is removed, loosened or made to accept more.",
                 "Existing checks are kept or strengthened; stating that they stay unweakened is false."),
    "retry": nl("Does `clause` add a retry or rerun of a failing test or run?",
                "A retry or rerun is added.", "No retry or rerun is added."),
}

Q_OBS = ch("Is `observation` something only a real AI provider run can show?",
           ["provider_only: it is about what a real model or real provider runtime does: its choices or tool calls, its latency, real authentication or login, whether the real runtime accepts, completes or authenticates something.",
            "offline: it is about Kogen's own outputs (arguments, files, records, sizes, hashes, controller decisions) that an offline test with fakes can check, even when a real run would also show it."],
           {"provider_only": "Only a real provider run can show it.", "offline": "An offline test with fakes can check it."})


def q_clause_offline(ref):
    return ch(f"Can clause `{ref}` be checked by an offline test with fake AI harnesses?",
              ["Kogen's own code (argument lists, files, records, parsing, controller decisions, stops) is checkable offline with fakes, even when the code is about a provider.",
               "Only what a real model or real provider runtime itself does (the model's choices or tool calls, its latency, real authentication, whether the real runtime accepts or completes something) needs a provider run."],
              {"offline": "An offline test with fakes can check it.",
               "provider_only": "It states what a real model or real provider runtime does."})


Q_PROV = ch("How is question entry `entry` resolved?",
            ["with_provenance: it states a decision and names its source, evidence, measurement, file, risk or reason.",
             "without_provenance: it states a decision but gives no source, evidence or reason.",
             "unresolved: it leaves the choice open or undecided."],
            {"with_provenance": "A decision with its source, evidence or reason.",
             "without_provenance": "A decision with no source, evidence or reason.",
             "unresolved": "The choice is left open."})


def main(pkg, out):
    scenarios = yaml_load(os.path.join(pkg, "scenarios.yaml")) or []
    risks = yaml_load(os.path.join(pkg, "risks.yaml")) or []
    intent = open(os.path.join(pkg, "INTENT.md")).read() if os.path.exists(os.path.join(pkg, "INTENT.md")) else ""
    qmd = open(os.path.join(pkg, "questions.md")).read() if os.path.exists(os.path.join(pkg, "questions.md")) else ""
    flags, jobs = [], []

    def scen_job(s):
        sid = s["id"]
        clauses = split_clauses(s.get("then"))
        alts = split_alternatives(s.get("wrong_result"))
        items = evidence_items(s.get("evidence"))
        proof = s.get("proof") or {}
        scen = {"id": sid, "given": norm(s.get("given")), "when": norm(s.get("when")), "then": " ".join(clauses),
                "wrong_result": "; ".join(alts), "evidence": norm(s.get("evidence")),
                "proof": {"offline": proof.get("offline"), "paid_target": proof.get("paid_target"), "paid_reason": norm(proof.get("paid_reason"))}}
        st = {"scenario": scen, "then_clauses": {f"c{i}": c for i, c in enumerate(clauses)},
              "wrong_result_alternatives": {f"w{j}": a for j, a in enumerate(alts)}}
        qs = {}
        for i in range(len(clauses)):
            qs[f"kind:c{i}"] = q_kind(f"then_clauses.c{i}"); qs[f"asserted:c{i}"] = q_asserted(f"then_clauses.c{i}")
        for j in range(len(alts)):
            qs[f"plaus:w{j}"] = q_plaus(f"wrong_result_alternatives.w{j}")
        A = ask(f"scenario:{sid}", st, qs)
        kinds = {}
        for i, c in enumerate(clauses):
            k, a = A[f"kind:c{i}"], A[f"asserted:c{i}"]
            kinds[i] = k["choice"]
            if k["choice"] == "unobservable" and k["confidence"] >= 0.8:
                flags.append(("then-unobservable", sid, c, k))
            if k["choice"] != "not_behaviour" and a["choice"] == "not_described" and a["confidence"] >= 0.8:
                flags.append(("then-without-described-proof", sid, c, a))
        for j, w in enumerate(alts):
            p = A[f"plaus:w{j}"]
            if p["choice"] != "plausible" and p["confidence"] >= 0.8:
                flags.append(("wrong-result-implausible", sid, w, p))
        # caught: Choice over evidence items + strict Noul, one request per alternative
        for j, w in enumerate(alts):
            crit = {f"e{k}": f"Evidence item e{k} checks it." for k in range(len(items))}
            crit["none"] = "No evidence item checks the thing wrong_behaviour gets wrong."
            st2 = {"then": scen["then"], "evidence": scen["evidence"], "offline_selectors": proof.get("offline"),
                   "evidence_items": {f"e{k}": t for k, t in enumerate(items)}, "wrong_behaviour": w}
            B = ask(f"caught:{sid}:w{j}", st2, {
                "caught_noul": Q_CAUGHT_NOUL,
                "caught_choice": ch("Which item in `evidence_items` would fail if the implementation behaved as `wrong_behaviour`?",
                                    ["Pick an item only if it explicitly checks the thing wrong_behaviour gets wrong.",
                                     "A general or happy-path test does not count; choose none."], crit)})
            none = B["caught_choice"]["choice"] == "none" and B["caught_choice"]["confidence"] >= 0.5
            low = B["caught_noul"]["noul"] < 0.6
            if none and low:
                flags.append(("wrong-result-not-caught", sid, w, {"choice": B["caught_choice"], "noul": B["caught_noul"]["noul"]}))
            elif none or low:
                flags.append(("weak-wrong-result-maybe-not-caught", sid, w, {"choice": B["caught_choice"], "noul": B["caught_noul"]["noul"]}))
        # hard rules, one request per clause
        for i, c in enumerate(clauses):
            H = ask(f"hard:{sid}:c{i}", {"clause": c}, HARD)
            hit = {k: v["noul"] for k, v in H.items() if k != "retry" and v["noul"] >= 0.75}
            if hit:
                flags.append(("hard-rule-risk", sid, c, hit))
            if H["retry"]["noul"] >= 0.9:
                flags.append(("info-retry-added", sid, c, {"retry": H["retry"]["noul"]}))
        # paid
        if proof.get("paid_target") not in (None, "none"):
            m = re.search(r"observation:\s*(.*?);\s*offline-limit", norm(proof.get("paid_reason")))
            if m:
                O = ask(f"paid-observation:{sid}", {"observation": m.group(1)}, {"o": Q_OBS})["o"]
                if O["choice"] == "offline" and O["confidence"] >= 0.8:
                    flags.append(("paid-observation-offline-checkable", sid, m.group(1), O))
        else:
            beh = [c for i, c in enumerate(clauses) if kinds.get(i) != "not_behaviour"]
            if beh:
                st3 = {"given": scen["given"], "when": scen["when"], "then_clauses": {f"c{i}": c for i, c in enumerate(beh)}}
                P = ask(f"provider-clauses:{sid}", st3, {f"pc:c{i}": q_clause_offline(f"then_clauses.c{i}") for i in range(len(beh))})
                for i, c in enumerate(beh):
                    a = P[f"pc:c{i}"]
                    if a["choice"] == "provider_only" and a["confidence"] >= 0.9:
                        flags.append(("offline-scenario-states-provider-behaviour", sid, c, a))

    # package-level
    def coverage_job():
        outcomes = list_items(md_section(intent, "Outcome"))
        if not outcomes or not scenarios:
            return
        scen = {s["id"]: norm(s.get("then"))[:1500] for s in scenarios}
        qs = {}
        for i in range(len(outcomes)):
            crit = {sid: f"Scenario {sid} states this outcome's observable result." for sid in scen}
            crit["none"] = "No scenario states this outcome's observable result."
            qs[f"cov:o{i}"] = ch(f"Which scenario in `scenarios` states the observable result of outcome `outcomes.o{i}`?",
                                 ["Pick the scenario whose `then` directly states this outcome's result.",
                                  "A scenario that only mentions the topic does not count; choose none."], crit)
        A = ask("coverage", {"outcomes": {f"o{i}": o[:2000] for i, o in enumerate(outcomes)}, "scenarios": scen}, qs)
        for i, o in enumerate(outcomes):
            a = A[f"cov:o{i}"]
            if a["choice"] == "none" and a["confidence"] >= 0.8:
                flags.append(("outcome-without-scenario", "-", o, a))

    def nongoal_job():
        ngs = list_items(md_section(intent, "Non-goals|Appetite and non-goals"))
        if not ngs:
            return
        for s in scenarios:
            crit = {f"n{i}": f"Non-goal n{i}." for i in range(len(ngs))}
            crit["none"] = "The scenario requires no listed non-goal."
            A = ask(f"nongoal:{s['id']}", {"scenario_then": norm(s.get("then")), "non_goals": {f"n{i}": t for i, t in enumerate(ngs)}},
                    {"leak": ch("Which non-goal in `non_goals`, if any, does `scenario_then` require doing?",
                                ["Choose a non-goal only when the scenario requires the excluded behaviour itself.",
                                 "Mentioning a related topic, or promising not to do it, is none."], crit)})["leak"]
            if A["choice"] != "none" and A["confidence"] >= 0.6:
                flags.append(("non-goal-leakage", s["id"], ngs[int(A["choice"][1:])], A))

    def prov_job():
        entries = [norm(q) for q in re.split(r"\n(?=\d+\. )", qmd) if re.match(r"\d+\. ", q)]
        for i, e in enumerate(entries):
            A = ask(f"question:{i}", {"entry": e[:3000]}, {"p": Q_PROV})["p"]
            if A["choice"] != "with_provenance" and A["confidence"] >= 0.8:
                flags.append(("question-" + A["choice"].replace("_", "-"), "-", e[:200], A))

    with ThreadPoolExecutor(12) as ex:
        list(ex.map(lambda f: f(), [lambda s=s: scen_job(s) for s in scenarios] + [coverage_job, nongoal_job, prov_job]))

    os.makedirs(out, exist_ok=True)
    json.dump({"version": VERSION, "model": MODEL, "package": pkg, "flags": flags, "exchanges": LOG},
              open(os.path.join(out, "jev-audit.json"), "w"), indent=1)
    tokens = sum((x["response"].get("usage") or {}).get("input_tokens", 0) for x in LOG)
    with open(os.path.join(out, "jev-audit.md"), "w") as f:
        f.write(f"# Jev audit ({VERSION}, {MODEL}), advisory\n\nPackage: `{pkg}`. Requests: {len(LOG)}. Input tokens: {tokens} (about ${tokens*0.042/1e6:.4f}).\n\n")
        f.write("| flag | scenario | text | answer |\n|---|---|---|---|\n")
        for kind, sid, text, ans in sorted(flags, key=lambda x: (x[0], x[1])):
            if isinstance(ans, dict) and isinstance(ans.get("choice"), dict):
                a = f"choice={ans['choice']['choice']} {ans['choice']['confidence']:.2f}, noul={ans['noul']:.2f}"
            elif isinstance(ans, dict) and "confidence" in ans:
                a = f"{ans['choice']} {ans['confidence']:.2f}"
            else:
                a = json.dumps(ans)
            f.write(f"| {kind} | {sid} | {text[:160].replace('|', '/')} | {a} |\n")
    print(f"{len(flags)} flags, {len(LOG)} requests, {tokens} input tokens -> {out}/jev-audit.md")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
