# Jev calibration: `finding-routing-v1` (technical / product_ux), 2026-09-25

Question: who must decide a questions.md `## Open` entry or an auditor finding,
the Shaping Controller (`technical`) or the human Shaper (`product_ux`)? The
Shaper's direction (2026-09-25): Shaping "shouldn't block (wait for shaper)
unless it's a ui/ux/product decision/question".

Method: `calibrate.py` (driver tool, Keychain item `dev.kogen.jev`, model
`jev-1.13.0`) sends each item alone as `state.item` with one Choice. Labels:
15 product items (decisions the Shaper actually made in `named-routes` and
`claude-code-harness` questions.md, DIRECTION D1, 3a Q1/Q2, and written
product questions) and 20 technical items (controller-decided entries,
settled technical questions of the 3a/3b/3c Drafts, real Sol/Astra findings,
written contract defects). The item text is the only thing sent.

| Wording | Set | Gate `product_ux` >= 0.6 | Notes |
|---|---|---|---|
| v0 (`raw-v0.json`) | 35 in-sample | product 11/15, technical routed to Shaper 3/20 | "Scope exceeds one Build" and "make this rule blocking" went to the Shaper. Rejected. |
| **v1** (`raw-v2.json`, the shipped wording `finding-routing-v1.question.json`) | 35 in-sample | **product 13/15, technical 0/20** | Misses: route naming (0.28) and "use Claude Code now, switch later" (0.29 on repeat). |
| v1 repeat (`raw-v2-repeat.json`) | 35 in-sample | product 13/15, technical 0/20 | Stable. |
| v1 held-out (`raw-v2-heldout.json`) | 12 new items | product 5/6, technical 0/6 | Miss: "Is a one-hour Build acceptable…" (0.17). |

(`raw-v2*.json` file names are historical: the second wording tried is
shipped as version `finding-routing-v1`.)

Gate: `product_ux` >= 0.6. The error mode is asymmetric and safe: at the gate
no technical item was routed to the Shaper (0/26), and 3 of 21 product items
were routed to the controller. A misrouted product question is not lost. The
hook blocks at most once per Draft revision, so a controller that believes an
entry needs the Shaper can stop again unchanged. The Shaper still sees every
settled decision in `questions.md` before approving, and approval stays
human (DIRECTION D1).

Limits: same-author labels, 47 items. Routing never approves anything and never
decides readiness. It only chooses whether a Shaping stop waits for the
Shaper, and how the hook groups auditor findings in its message.

---

# Jev calibration: `question-gate-v1` (use 12), 2026-09-25 Claude Shaping continuation

Why: auditing this Intent against its own rules found a defect in
`finding-routing-v1`. Its `technical` rule includes "splitting work into
Builds", but DIRECTION 1.17 (Shaper, 2026-09-25) makes a split or deferral of
requested scope a decision for the Shaper. The addition A6 also asks for use
12's `already_settled` route, so a settled matter is answered by citing the
decision instead of being asked again.

Shipped definition: `question-gate-v1.question.json`. It has three questions
in one request. State: `item`, plus `settled`, the list of `{id, text}`
decisions. The audit builds that list from the DIRECTION decisions and the
Draft's own `## Settled` entries.
- `gate`: a Choice of technical / product_ux / already_settled. Splitting or
  deferring requested scope is product_ux.
- `settled_by`: a Choice over the decision ids + none.
- `confirm`: a Noul, "does decision X by itself fully answer the item?", sent
  in a second request with the cited decision.

Routing (the Controller never decides a product question by itself):
1. **cite**, when `already_settled >= 0.8`, `settled_by` names a decision with
   confidence `>= 0.8`, and `confirm >= 0.6`. The Controller records the item
   under `## Settled`, citing the decision id and text, so the Shaper still
   sees it before approval.
2. **controller**, when `technical >= 0.5`.
3. **Shaper**, for everything else (the safe default).

Method: `calibrate_gate_v3.py` (Keychain `dev.kogen.jev`, `jev-1.13.0`, item
text and short decision paraphrases only). Offline scoring is
`evaluate_gate_v3.py`, the held-out set is `heldout_gate_v3.py` (written
before its results were seen), and the citation check is `confirm_cite_v3.py`.
Labels: the 47 `finding-routing-v1` items plus 15 new ones. There are three
relabels. "Scope exceeds one Build … Split it" becomes P (DIRECTION 1.17).
"May Kogen Studio approve …" and "defer the paid-target health reader …"
become S, because a listed decision (1.13, 1.17) answers them.

| Run | P reach Shaper | T sent to Shaper | S cited correctly | Wrong citations before confirm |
|---|---|---|---|---|
| in-sample `raw-gate-v3.json` (62) | 22/22 | 3/29 | 9/11 | 0 |
| repeat `raw-gate-v3-repeat.json` | 22/22 | 3/29 | 9/11 | 0 |
| held-out `raw-gate-v3-heldout.json` (22) | 7/8 | 0/8 | 3/6 | 1 |

The held-out wrong citation cited `shp-auditor-profile` for "Should the
auditor also run when the Shaper uses the Codex route directly without mix
kogen.shape?", a product question on a related topic. `confirm` scored it
0.45 in the first run and 0.43 in the second. Every correct citation scored
≥ 0.62, except "which harness … claude-dominant-adversarial-codex" (0.44 and
0.51, which then goes to the Shaper, the safe direction). With `confirm >= 0.6`
the calibrated sets have **0 wrong citations**. The held-out product miss is
exactly that item, so with the confirm gate it now reaches the Shaper:
**held-out product 8/8**. The other held-out S misses fall back to the Shaper
or the controller. They are asked, never silently answered.

Files: `raw-confirm-v3.json` holds the second confirm run. The first valid
run's values are the ones quoted above.
`raw-confirm-v3-INVALID-item-mismatch.json` is an **invalid** run: importing
the held-out module replaced the in-sample item list, so its rows pair
results with the wrong items. It is kept only as a record of that.

Limits: same-author labels, 84 items, one model version. Routing never
approves anything and never decides readiness. Misrouting fails safe
towards asking the Shaper. The costly direction, a product question answered
by citation, is the one with a second check. `finding-routing-v1` is
superseded by `question-gate-v1`.
