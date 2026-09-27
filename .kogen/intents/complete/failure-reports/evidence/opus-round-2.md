**Verdict: ready**

All three round-1 blockers are fixed, and the five files agree with each other and with fa48e817.

1. **Drop list is fixed.** INTENT.md:48-59 and references.yaml:8-16 now drop everything that belongs to the later slices:
   - the `reconcile(control)` call in `run/3` (diff:17);
   - the `%{"published" => false}` detail (diff:181);
   - `reconcile/1` and `file_sha/1` (diff:542-610);
   - the rows `interrupted`, `publication-interrupted` and `session-lost` (diff:440-442);
   - the fields `continues`, `budget_state`, `published` and `continuable` (diff:502-526), plus the `budget_state/1` helper;
   - the `published:` branch and the "written by the next" text (diff:986-990);
   - `continuation.ex`, the workspace and tracking hunks, and the continuation test.

   None of the kept code calls anything dropped. The only dependency on `Tracking.approved_digest` or `Workspace.published?` is in dropped code. questions.md Assumed 16 and Audit record the change.

2. **The category mechanism is fixed.** INTENT.md:149-165 gives one shape: the category is passed explicitly as `stop_category` where the call site knows it, the unchanged `stop_category/1` table handles the rest, and it's evaluated once in `stop`. That matches the code:
   - `stop/3` already does `details["stop_category"] || stop_category(reason)` (build.ex:2253), and the existing explicit call sites are at build.ex:790/817/857/1398.
   - Every error from `Harness.open_roles/4` is a readiness error ("… is not ready", harness.ex:154). It reaches `stop` through `admission_step` (build.ex:442-444), so it has to carry the category there, as the INTENT says.
   - The missing-deps case is detected in `Workspace.create`, so it goes through `record_failure` with `candidate` null, which is consistent with case (f).

   The key stays `stop_category` (Assumed 12), and the Candidate's `infer_category_override/1` is not taken. The "one category, three places" test (INTENT.md:296-300, scenarios.yaml:26-27) now closes the F1 gap. risks.yaml `categories-preserved` agrees and notes that the paid-target login stop has to pass its category explicitly.

3. **Paid-target login is fixed.**
   - The cycle failure `reason` text is now exact (INTENT.md:205-209, scenarios.yaml:63-64, controller_verification test at INTENT.md:335-338, Assumed 14).
   - The `stop_reason("environment", …)` wrapper (build.ex:1547-1549) is replaced only when the marker kind is `login_rejected`.
   - The command follows the tail's harness (Assumed 15), and a shared scope falls back to the cycle reason's command.
   - Scope stays limited to verification.ex (Non-goals INTENT.md:415), and every touched path is listed in `may_change_guarded_paths`.

**Non-blocking (worth a one-word fix):** INTENT.md:33-34 says "Fix its `Reproduce:` fallback: it is `make check`, not the generic line below." A Developer could read "it is `make check`" as the value to use. The same wording appears at INTENT.md:37-38. The Outcome section (INTENT.md:235-240) and the handoff tests (INTENT.md:343-344) settle it the right way, but "it is currently `make check`; make it the generic line below" would remove the doubt.

Plan mode asked for a plan file and ExitPlanMode, but neither tool is available in this session, so this reply is the whole review. The claude.ai Stripe connector still needs to be authorized in your claude.ai connector settings; this review didn't need it.
