"""Deterministic preparation: scenario `then` -> clauses; per-scenario diff -> hunks with stable IDs."""
import re, subprocess, json, sys
sys.path.insert(0, __file__.rsplit("/",1)[0])
REPO="/Users/almirsarajcic/Areas/Kogen/kogen"
def sh(*a): return subprocess.run(a,cwd=REPO,capture_output=True,text=True).stdout
def clauses(text):
    parts=re.split(r"(?<=[.;])\s+(?=[A-Z`(])", " ".join(str(text).split()))
    return [p.strip() for p in parts if len(p.strip())>3]
def hunks(base, tree, paths):
    if not paths: return []
    d=sh("git","diff","-U3",base,tree,"--",*paths)
    out=[]; cur_file=None; buf=None
    for line in d.splitlines():
        if line.startswith("diff --git"):
            if buf: out.append(buf); buf=None
            cur_file=line.split(" b/",1)[1]
        elif line.startswith("@@"):
            if buf: out.append(buf)
            buf={"file":cur_file,"header":line,"lines":[]}
        elif buf is not None and not line.startswith(("+++","---","index ","new file","deleted file")):
            buf["lines"].append(line)
    if buf: out.append(buf)
    for i,h in enumerate(out): h["id"]=f"h{i+1}"; h["text"]=f"{h['file']} {h['header']}\n"+"\n".join(h["lines"]); del h["lines"]
    return out
