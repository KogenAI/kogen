"""Held-out set for question-gate-v1 (written before seeing any result on it)."""
import os, calibrate_gate_v3 as c
HELD = [
 ("P","h","Should mix kogen.audit colour its output, or print plain text only?"),
 ("P","h","Should a Build that fails its audit gate offer to run the audit automatically?"),
 ("P","h","Should Kogen support GitLab merge requests in this Intent?"),
 ("P","h","Should the Shaping session show the Jev probabilities to the Shaper?"),
 ("P","h","Should the auditor also run when the Shaper uses the Codex route directly without mix kogen.shape?"),
 ("P","h","Should the audit spend up to five dollars per Draft on extra auditor passes?"),
 ("P","h","Should the ledger refresh work be moved to its own Intent so this one stays small?"),
 ("P","h","Should Linux support for the Stop hook be dropped from this Intent?"),
 ("T","h","The jev-layer scenario lists fake_jev_audit in affected_paths but may_change_guarded_paths does not cover it."),
 ("T","h","Should Kogen.AuditReport read report.json with Jason or with a hand-written parser?"),
 ("T","h","The stale-anchor rule must compare line text, not just file existence."),
 ("T","h","Should the materialization use git archive or git worktree add?"),
 ("T","h","The wrong_result of build-admission-gate is not caught by any evidence item; add a direct Kogen.Build.run/2 call."),
 ("T","h","Should prior-failure lookup scan record.json files newest first with a 50-record bound?"),
 ("T","h","Should the sibling check treat a shared test support file as an intersection?"),
 ("T","h","Rename the finding id controller-frozen-path to controller-read-path and include .codex/hooks.json."),
 ("S:dir-1.16","h","Should the auditor route key be added now even though nothing launches the auditor until a later Intent?"),
 ("S:dir-1.13","h","Once the report is ready, may the Shaping Controller move the Draft to approved without asking?"),
 ("S:dir-1.17","h","Should the Build admission gate be split into its own Intent to avoid touching Build?"),
 ("S:shp-auditor-profile","h","On the claude-dominant-adversarial-codex route, which harness should run the auditor?"),
 ("S:dir-1.15","h","Should questions.md refer to the dependency as #2 or as cross-harness-adversarial-roles?"),
 ("S:shp-wait-only-product","h","Should the Stop hook block and wait for the Shaper when only technical findings remain?"),
]
c.items = lambda: HELD
if __name__ == "__main__":
    os.environ.setdefault("TAG", "v3-heldout"); c.main()
