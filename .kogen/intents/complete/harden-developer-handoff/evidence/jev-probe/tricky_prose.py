#!/usr/bin/env python3
"""Synthetic, hand-labelled tricky Developer notes (authored by the Shaping Controller; labels fixed before running)."""
import json, sys, concurrent.futures as cf
sys.path.insert(0, sys.argv[1]); import probe
OUT=sys.argv[1]
# (label, notes, {item: (unfinished, cannot_comply)})
C=[
("negation","All three scenarios are done. Nothing in parse-config remains unfinished, and retry-budget has no missing parts.",{"parse-config":(0,0),"retry-budget":(0,0),"report-errors":(0,0)}),
("fixed-since","parse-config was incomplete after my first pass, but I finished the missing YAML anchors and it is now complete. retry-budget and report-errors are done.",{"parse-config":(0,0),"retry-budget":(0,0),"report-errors":(0,0)}),
("feature-named-incomplete","report-errors now renders the `incomplete` status label correctly and handles the `unfinished` enum value. parse-config and retry-budget are done.",{"parse-config":(0,0),"retry-budget":(0,0),"report-errors":(0,0)}),
("non-goal","parse-config and retry-budget are done. report-errors is done; streaming output is out of scope per the Intent's non-goals and was not implemented.",{"parse-config":(0,0),"retry-budget":(0,0),"report-errors":(0,0)}),
("hedge","parse-config is mostly done, but the error path for duplicate keys still needs work. retry-budget and report-errors are done.",{"parse-config":(1,0),"retry-budget":(0,0),"report-errors":(0,0)}),
("todo-later","retry-budget works for the happy path; I did not get to the exhaustion case yet. The others are finished.",{"parse-config":(0,0),"retry-budget":(1,0),"report-errors":(0,0)}),
("indirect-objection","Everything I could do is done. report-errors requires changing lib/kogen/cli.ex, but that file is not in may_change_guarded_paths, so I could not make the change the scenario demands.",{"parse-config":(0,0),"retry-budget":(0,0),"report-errors":(0,1)}),
("contradiction-objection","parse-config says unknown keys must fail, while retry-budget says unknown keys must be ignored; both cannot hold for the same file, so this needs a Shaping decision. report-errors is done.",{"parse-config":(0,1),"retry-budget":(0,1),"report-errors":(0,0)}),
("objection-plus-unfinished","parse-config is unfinished: I ran out of time on the anchors. Separately, retry-budget cannot be satisfied as approved because its proof target cannot observe the provider retry. report-errors is done.",{"parse-config":(1,0),"retry-budget":(0,1),"report-errors":(0,0)}),
("reviewer-disputed","Finding F1 claims report-errors is missing a newline; I disagree, the newline is emitted at line 40 and the test asserts it. All scenarios are done.",{"parse-config":(0,0),"retry-budget":(0,0),"report-errors":(0,0)}),
("blocked-env","All code is done. The live check for retry-budget could not run here because the provider login was missing; the implementation itself is complete.",{"parse-config":(0,0),"retry-budget":(0,0),"report-errors":(0,0)}),
("terse-prose","done: parse-config, report-errors. retry-budget: exhaustion branch TODO.",{"parse-config":(0,0),"retry-budget":(1,0),"report-errors":(0,0)}),
]
cu={"yes":"the notes say part of this item is still unfinished, missing or incomplete","no":"the notes present this item as done"}
cc={"yes":"the notes say the approved contract for this item cannot be met as written (e.g. a required change is outside the allowed paths, requirements contradict, or it needs to return to Shaping)","no":"the notes raise no such contract objection for this item"}
def run(case):
    lab,notes,items=case; qs={}
    for i in items:
        qs[f"unfinished:{i}"]={"type":"choice","instructions":{"task":f"Read developer_notes. Does the Developer say anything required by scenario `{i}` is still unfinished?","rules":["Judge only what the notes state; do not judge code."]},"criteria":cu}
        qs[f"cannot_comply:scenario:{i}"]={"type":"choice","instructions":{"task":f"Read developer_notes. Does the Developer say the approved contract for scenario `{i}` cannot be met as written?","rules":["Judge only what the notes state.","Unfinished work alone is not a contract objection."]},"criteria":cc}
    res=[]
    for rep in range(3):
        st,lat,nb,out=probe.call({"model":"jev-1.13.0","state":{"developer_notes":notes},"questions":qs})
        res.append({"status":st,"answers":out.get("answers"),"usage":out.get("usage")})
    return {"label":lab,"notes":notes,"truth":items,"runs":res}
with cf.ThreadPoolExecutor(4) as ex: R=list(ex.map(run,C))
json.dump(R,open(f"{OUT}/tricky-prose.json","w"),indent=1)
for r in R:
    for i,(u,c) in r["truth"].items():
        for q,t in ((f"unfinished:{i}",u),(f"cannot_comply:scenario:{i}",c)):
            got=[(a["answers"][q]["choice"],a["answers"][q]["confidence"]) for a in r["runs"] if a["answers"]]
            bad=[g for g in got if (g[0]=="yes")!=bool(t)]
            if bad: print("WRONG",r["label"],q,"truth",t,got)
print("done")
