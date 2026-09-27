"""Second check for question-gate-v1 citations: a Noul per (item, cited decision)."""
import json, urllib.request
from concurrent.futures import ThreadPoolExecutor
import calibrate_gate_v3 as c
ORIG = c.items
import evaluate_gate_v3 as e, heldout_gate_v3 as h
CONFIRM = {"type": "noul", "instructions": {"task": "Does decision `decision` by itself fully answer what item `item` asks, so that nobody needs to be asked? Answer no if the decision is only about a related topic, or answers only part of it."}}
def ask(item, dec):
    body = json.dumps({"model": c.MODEL, "state": {"item": item, "decision": dec}, "questions": {"c": CONFIRM}}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", data=body, headers={"authorization": "Bearer " + c.KEY, "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r: return json.loads(r.read())["answers"]["c"]["noul"]
text = {d["id"]: d["text"] for d in c.SETTLED}
cands = []
orig = ORIG
for tag, its in (("v3", orig), ("v3-repeat", orig), ("v3-heldout", lambda: h.HELD)):
    e.c.items = its
    for l, t, te, pr, se, by, bp in e.load(tag):
        if se >= 0.8 and by != "none" and bp >= 0.8: cands.append((tag, l, t, by))
with ThreadPoolExecutor(8) as p: ps = list(p.map(lambda x: ask(x[2], text[x[3]]), cands))
out = [{"tag": a, "label": l, "item": t, "cited": by, "confirm": p} for (a, l, t, by), p in zip(cands, ps)]
json.dump(out, open("raw-confirm-v3.json", "w"), indent=1)
for o in sorted(out, key=lambda o: o["confirm"]):
    ok = o["label"] == "S:" + o["cited"]
    print(f"{o['confirm']:.2f} {'OK ' if ok else 'BAD'} {o['tag']:10} {o['cited']:22} {o['item'][:70]}")
