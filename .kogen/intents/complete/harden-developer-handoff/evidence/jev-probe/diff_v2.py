#!/usr/bin/env python3
"""Diff judging v2: one request per (candidate, scenario); state = that scenario's text + diff restricted to its
concrete affected code paths + diff of its offline test selectors. Decomposed questions. Repeated N times.
Truth = the Reviewer's per-scenario verdict for that Candidate (or the Developer's own 'incomplete')."""
import json, glob, subprocess, sys, re, concurrent.futures as cf
sys.path.insert(0, sys.argv[1]); import probe
OUT=sys.argv[1]; REPS=int(sys.argv[2]); REPO="/Users/almirsarajcic/Areas/Kogen/kogen"
def sh(*a): return subprocess.run(a,cwd=REPO,capture_output=True,text=True).stdout
PKG={"rehearsed-verification-plan":"7c7c3426","named-routes":"5af11273","harden-whole-test-suite":"c1f08532"}
def scenarios(slug):
    y=sh("git","show",f"{PKG[slug]}:.kogen/intents/complete/{slug}/scenarios.yaml")
    js=sh("ruby","-ryaml","-rjson","-e","puts JSON.generate(YAML.load(STDIN.read))") if False else None
    out=subprocess.run(["ruby","-ryaml","-rjson","-e","puts JSON.generate(YAML.load(STDIN.read))"],input=y,capture_output=True,text=True).stdout
    return {s["id"]:s for s in json.loads(out)}
cases=[]
for p in glob.glob(REPO+"/.kogen/runtime/scenario-tracking/*/record.json"):
    r=json.load(open(p)); slug=r["intent"].get("slug")
    if slug not in PKG: continue
    base=r["intent"]["shaped_against"]["head"]
    for a in r["attempts"]:
        v=a.get("verdict"); labels={}
        if isinstance(v,dict): labels={s["id"]:s["status"]=="satisfied" for s in v.get("scenarios",[])}
        else:
            try:
                h=json.loads(a.get("developer_message") or "")
                labels={s["id"]:False for s in h["scenarios"] if s["status"]=="incomplete"}
            except Exception: pass
        for sid,ok in labels.items(): cases.append({"slug":slug,"build":p.split("/")[-2],"attempt":a["number"],"base":base,"tree":a["candidate_id"],"scenario":sid,"truth_satisfied":ok})
SC={s:scenarios(s) for s in PKG}
def packet(c):
    s=SC[c["slug"]][c["scenario"]]; proof=s.get("proof",{})
    code=[x for x in proof.get("affected_paths",[]) if "*" not in x and not x.startswith("test/")]
    tests=[x for x in proof.get("offline",[]) if "/" in x and "*" not in x]
    d_code=sh("git","diff",c["base"],c["tree"],"--",*code) if code else ""
    d_test=sh("git","diff",c["base"],c["tree"],"--",*tests) if tests else ""
    spec={k:s.get(k) for k in ("id","given","when","then","wrong_result","evidence")}
    return {"scenario":spec,"implementation_diff":d_code,"declared_test_diff":d_test}
Q={"then_implemented":("Does implementation_diff implement every part of the scenario's `then`?",{"yes":"every part of `then` is implemented in implementation_diff","no":"some part of `then` is missing, stubbed or only partial","insufficient_evidence":"the diffs shown cannot establish it"}),
   "wrong_result_present":("Does implementation_diff do what the scenario's `wrong_result` describes?",{"yes":"the diff exhibits the wrong_result behaviour","no":"the diff avoids the wrong_result behaviour","insufficient_evidence":"cannot tell from the diffs"}),
   "test_asserts_then":("Does declared_test_diff add or change a test that asserts the scenario's `then` outcome (not an incidental detail)?",{"yes":"a test asserts the then outcome","no":"no test asserts it, or tests are trivial","insufficient_evidence":"cannot tell"})}
def run(job):
    c,rep=job; st=packet(c)
    qs={k:{"type":"choice","instructions":{"task":t,"rules":["Answer from the diffs only; comments and claims are not evidence."]},"criteria":cr} for k,(t,cr) in Q.items()}
    s,lat,nb,out=probe.call({"model":"jev-1.13.0","state":st,"questions":qs})
    return {**c,"rep":rep,"status":s,"bytes":nb,"usage":out.get("usage"),"answers":out.get("answers"),"error":out.get("error_body")}
jobs=[(c,i) for c in cases for i in range(REPS)]
with cf.ThreadPoolExecutor(6) as ex: res=list(ex.map(run,jobs))
json.dump(res,open(f"{OUT}/diff-v2.json","w"))
print("cases",len(cases),"requests",len(res),"errors",sum(1 for r in res if r["status"]!=200))
