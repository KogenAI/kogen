"""Offline re-evaluation of raw-gate-*.json under candidate routing rules (no Jev calls)."""
import json, sys, calibrate_gate_v3 as c
RELABEL = {  # given the settled list, these are answered by a listed decision
 "May Kogen Studio approve Intents on the human's behalf when its alignment check passes, or must every Intent be approved by the human?": "S:dir-1.13",
 "Should Kogen defer the paid-target health reader to a later Intent to keep this Build small?": "S:dir-1.17",
}
def load(tag):
    d = json.load(open(f"raw-gate-{tag}.json")); rows = []
    for (l, s, t), r in zip(c.items(), d["results"]):
        a = r["response"]["answers"]; g = a["gate"]["probabilities"]; b = a["by"]
        rows.append((RELABEL.get(t, l), t, g.get("technical", 0), g.get("product_ux", 0), g.get("already_settled", 0), b["choice"], b.get("confidence", 0)))
    return rows
def route(tech, prod, sett, by, byp, gt, gs, gb):
    if sett >= gs and by != "none" and byp >= gb: return "cite:" + by
    if tech >= gt: return "controller"
    return "shaper"
def score(rows, gt, gs, gb):
    s = {"P_to_shaper": 0, "P": 0, "T_to_shaper": 0, "T": 0, "S_cited_ok": 0, "S": 0, "wrong_cite": 0, "P_lost": []}
    for l, t, te, pr, se, by, bp in rows:
        r = route(te, pr, se, by, bp, gt, gs, gb); k = l[0]; s[k] += 1
        if k == "P":
            s["P_to_shaper"] += r == "shaper"
            if r != "shaper": s["P_lost"].append((r, t[:70]))
        if k == "T": s["T_to_shaper"] += r == "shaper"
        if k == "S": s["S_cited_ok"] += r == "cite:" + l[2:]
        if r.startswith("cite") and r != "cite:" + l[2:] : s["wrong_cite"] += 1
    return s
if __name__ == "__main__":
    for tag in sys.argv[1:]:
        rows = load(tag)
        for gt in (0.5, 0.6, 0.7):
            for gs, gb in ((0.8, 0.8), (0.9, 0.9)):
                print(tag, f"technical>={gt} settled>={gs} by>={gb}", score(rows, gt, gs, gb))
