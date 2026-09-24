#!/usr/bin/env python3
"""Shaping probe: can Jev judge per-scenario implementation from Intent scenarios + Candidate diff?
Key is read from the Keychain into the request header only; never printed or stored."""
import json, subprocess, sys, time, urllib.request, urllib.error
REPO="/Users/almirsarajcic/Areas/Kogen/kogen"
def sh(*a): return subprocess.run(a,cwd=REPO,capture_output=True,text=True,check=True).stdout
def packet(base, tree, scenarios_rev, slug, include_tests=True):
    scen=sh("git","show",f"{scenarios_rev}:.kogen/intents/complete/{slug}/scenarios.yaml")
    paths=["lib","priv","scripts",".codex","Makefile","README.md","mix.exs"]+(["test"] if include_tests else [])
    diff=sh("git","diff",base,tree,"--",*paths,":(exclude)priv/kogen/test-reliability*.yaml",":(exclude).kogen")
    return scen, diff
def ids(scen):
    return [l.split(":",1)[1].strip() for l in scen.splitlines() if __import__("re").match(r"^\s*-\s*id:",l)]
def request(scen, diff):
    state={"approved_scenarios_yaml":scen,"candidate_diff_against_build_base":diff}
    qs={}
    for sid in ids(scen):
        qs[f"implemented:{sid}"]={"type":"choice",
          "instructions":{"task":f"Judge scenario `{sid}` from approved_scenarios_yaml against candidate_diff_against_build_base.",
            "rules":["Answer from the diff only; claims in comments are not evidence.",
                     "yes: the diff implements this scenario's `then` completely and avoids its `wrong_result`.",
                     "no: some required part of `then` is missing, stubbed, or the diff does what `wrong_result` describes.",
                     "insufficient_evidence: the diff shown cannot establish either."]},
          "criteria":{"yes":"scenario fully implemented","no":"scenario not fully implemented","insufficient_evidence":"cannot tell from the diff"}}
    return {"model":"jev-1.13.0","state":state,"questions":qs}
def call(body):
    key=subprocess.run(["security","find-generic-password","-w","-s","ai.typesafe.api"],capture_output=True,text=True,check=True).stdout.strip()
    data=json.dumps(body).encode()
    req=urllib.request.Request("https://api.typesafe.ai/v1/systemone",data=data,headers={"Authorization":"Bearer "+key,"Content-Type":"application/json"})
    t=time.time()
    try:
        with urllib.request.urlopen(req,timeout=180) as r: out=json.loads(r.read()); status=r.status
    except urllib.error.HTTPError as e: out={"error_body":e.read().decode()[:2000]}; status=e.code
    return status, round(time.time()-t,2), len(data), out
if __name__=="__main__":
    label, base, tree, rev, slug, tests = sys.argv[1:7]
    scen, diff = packet(base, tree, rev, slug, tests=="tests")
    status, lat, nbytes, out = call(request(scen, diff))
    json.dump({"label":label,"base":base,"tree":tree,"slug":slug,"include_tests":tests=="tests","request_bytes":nbytes,"diff_bytes":len(diff),"status":status,"latency_s":lat,"response":out},open(f"{sys.argv[7]}/{label}.json","w"),indent=1)
    print(label,"status",status,"bytes",nbytes,"lat",lat,"usage",out.get("usage"))
    for k,v in (out.get("answers") or {}).items(): print(" ",k,v.get("choice"),v.get("confidence"))
    if "error_body" in out: print(out["error_body"][:500])
