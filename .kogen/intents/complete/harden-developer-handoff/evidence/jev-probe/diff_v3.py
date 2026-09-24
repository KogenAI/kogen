#!/usr/bin/env python3
"""Diff judging v3 (citation-check + line-by-line search patterns):
 1) code splits `then` into clauses and the scenario diff into ID-tagged hunks;
 2) request A (per case): per clause a Choice over hunk IDs (+none) to locate, and a Noul 'does any hunk implement it';
 3) request B (per clause): state = clause + wrong_result + located top hunk; Choice supports/contradicts/says_nothing.
Truth = Reviewer per-scenario verdict (or Developer's own incomplete)."""
import json, sys, concurrent.futures as cf
sys.path.insert(0, sys.argv[1]); import probe, hunks as H
OUT=sys.argv[1]
V2=json.load(open(OUT+"/diff-v2.json"))
cases={}
for r in V2: cases[(r["slug"],r["build"],r["attempt"],r["scenario"])]={k:r[k] for k in ("slug","build","attempt","base","tree","scenario","truth_satisfied")}
cases=list(cases.values())
import subprocess
PKG={"rehearsed-verification-plan":"7c7c3426","named-routes":"5af11273","harden-whole-test-suite":"c1f08532"}
SC={}
for slug,rev in PKG.items():
    y=subprocess.run(["git","show",f"{rev}:.kogen/intents/complete/{slug}/scenarios.yaml"],cwd=H.REPO,capture_output=True,text=True).stdout
    SC[slug]={s["id"]:s for s in json.loads(subprocess.run(["ruby","-ryaml","-rjson","-e","puts JSON.generate(YAML.load(STDIN.read))"],input=y,capture_output=True,text=True).stdout)}
def run(c):
    s=SC[c["slug"]][c["scenario"]]; proof=s.get("proof",{})
    paths=[x for x in proof.get("affected_paths",[]) if "*" not in x and not x.startswith("test/")]+[x for x in proof.get("offline",[]) if "/" in x and "*" not in x]
    hs=H.hunks(c["base"],c["tree"],paths); cl=H.clauses(s.get("then",""))
    res={**c,"clauses":cl,"n_hunks":len(hs)}
    if not hs: res["outcome"]="no_hunks"; return res
    if len(hs)>250: res["outcome"]="too_many_hunks"; return res
    doc="\n\n".join(f"{h['id']}| {h['text']}" for h in hs)
    if len(doc)>100_000: res["outcome"]="too_large"; return res
    qa={}
    for i,t in enumerate(cl):
        qa[f"where:{i}"]={"type":"choice","instructions":f"Which diff hunk in `diff` most directly implements this expected behaviour: \"{t}\"? Choose none if no hunk implements it.","criteria":{**{h["id"]:None for h in hs},"none":"No hunk implements this behaviour."}}
        qa[f"exists:{i}"]={"type":"noul","instructions":f"Does any hunk in `diff` implement this expected behaviour: \"{t}\"?","criteria":{"true":"At least one hunk adds or changes code that directly produces this behaviour.","false":"No hunk produces this behaviour; it is absent, stubbed or only mentioned in comments."}}
    st,lat,nb,out=probe.call({"model":"jev-1.13.0","state":{"diff":doc},"questions":qa})
    res["locate_status"]=st; res["locate_usage"]=out.get("usage")
    if st!=200: res["outcome"]=f"locate_http_{st}"; res["error"]=out.get("error_body"); return res
    A=out["answers"]; by={h["id"]:h for h in hs}; res["clause_results"]=[]
    for i,t in enumerate(cl):
        w=A[f"where:{i}"]; ex=A[f"exists:{i}"]["noul"]
        top=w["choice"]
        entry={"clause":t,"where":top,"where_conf":w["confidence"],"exists":ex}
        if top!="none":
            q={"relation":{"type":"choice","instructions":"How does the diff hunk relate to the expected behaviour?","criteria":{
                "supports":"The hunk adds or changes code that directly produces the expected behaviour.",
                "contradicts":"The hunk produces the wrong_result or the opposite of the expected behaviour.",
                "says_nothing":"The hunk does not address the expected behaviour either way."}}}
            st2,_,_,o2=probe.call({"model":"jev-1.13.0","state":{"expected_behaviour":t,"wrong_result":s.get("wrong_result",""),"hunk":by[top]["text"]},"questions":q})
            if st2==200: a=o2["answers"]["relation"]; entry.update(relation=a["choice"],relation_conf=a["confidence"])
            else: entry["relation"]=f"http_{st2}"
        res["clause_results"].append(entry)
    res["outcome"]="ok"; return res
with cf.ThreadPoolExecutor(6) as ex: R=list(ex.map(run,cases))
json.dump(R,open(OUT+"/diff-v3.json","w")); print("cases",len(R),{o:sum(1 for r in R if r["outcome"]==o) for o in {r["outcome"] for r in R}})
