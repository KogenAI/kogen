# Decisions and execution notes

1. Resolved by the human on 2026-09-09: ten seconds is only a guideline,
   not a hard requirement. Remove the elapsed-time failure cutoff; retain
   complete timing reports and correctness failures. The recorded 9.62-second
   run demonstrates the guideline was reached.
2. Cold-cache verification ownership: the prior package requires an initially
   empty private MIX_BUILD_PATH but gives no automated owner invocation for it.
   Recommendation for discussion: the existing outer-owned live driver performs
   one complete cold offline check in an isolated copy with installed dependencies,
   provider denial and no downloads, retaining its full log. It must exclude live
   tests to prevent recursion; this deliberate cold validation is separate from
   the bounded fake-lifecycle fixture checks. Alternatively the human can select
   a separate owner-run acceptance step. No new Make target or public interface
   has been chosen. Choose a legitimate owner-run execution path before claiming cold acceptance.
3. Re-entry after a stopped Build: ordinary Build requires a clean tree. The
   unfinished candidate is preserved and must not be discarded or prematurely
   committed by shaping. Establish an authorized way to continue the existing
   Developer work or stage an isolated buildable baseline before invoking Build;
   do not imply that approving this Draft alone makes a dirty checkout runnable.

The existing full-coverage, all-async, approximate ten-second warm performance guideline and cold
offline success requirements remain accepted prior product decisions.
No new public interface or UX is proposed. The human explicitly approved this
revision with “Approve the Intent” and instructed that handoff concerns not
block approval. Build/Shape resumption is a separate future shaping topic.

Metadata: shaping.started is the first captured UTC clock reading in this
conversation; exact launch time was not supplied. Model/effort record the
configured shaping launch profile, not a claim of changing the active model.
