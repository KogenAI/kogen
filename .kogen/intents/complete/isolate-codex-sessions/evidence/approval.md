> Historical September 10 record; not current-conversation approval.
> Current lifecycle and continuation findings are recorded in [INTENT.md](../INTENT.md).

> Historical visit (2026-09-10T09:50:00.754357Z): the Shaper explicitly approved
> the revised draft with “and yeah I approve”. See evidence/approval-current-visit.md.
> Earlier approval statements below retain their historical provenance.

# Approval provenance: managed-runtime revision

Identity: 01a0853e-d297-744b-9cd1-bd0ed3f523fe / isolate-codex-sessions.
Same continuation started 2026-09-10T05:57:04.107462Z; no additional provider
session or shaping visit has been invented. Original shaping and shaped_against
metadata remain unchanged; current reassessment remains main/bf68fd70.

## Historical approval and failed Build

The earlier package was approved after the Shaper said “Yes. Don't stop. Then
approve.” It reused the installed executable and existing credentials, excluding
managed installation. That package is preserved in history/prior-approved-package.tar.gz.
It is historical authority for the failed Build, not approval of this revision.

The Build stopped after two outer resumptions. All three Stop Checks passed;
each attempt failed the live target, with no top-level independent Review reached.
The first failure was hostile-fixture legacy configuration, the second an XDG
absence assertion, and the final failure was a separate Reviewer challenge
rejecting its corrected fixture. The final isolation lifecycle test passed but
the complete implementation never earned acceptance. Source record remains
.kogen/runtime/scenario-tracking/BuV1DiqGIQDmrbdb8e--nNyU/record.json and is not a
restart checkpoint. The Shaper subsequently stashed the implementation and chose
to proceed without expecting to reuse it; no stash was popped or deleted here.

## Revision decisions

- After discussing update behavior, the Shaper accepted explicit update/status
  commands with “Ok, now that's good!”
- The Shaper rejected automatic initial installation and proposed explicit
  `mix kogen.codex.install`, with installation checks before both shape and build.
- The Shaper accepted `mix kogen.codex.login` as delegation to native Codex login,
  explicitly rejecting duplicated subscription/API-key handling by Kogen.
- The Shaper reconsidered copy/sync reuse. Delegated synthetic and official-doc
  investigations exposed local-write and refresh coupling. Fresh separate Kogen
  login was then presented as the requirement before first provider work.
- The Shaper chose “One Kogen login with ability to set up per project”, for
  personal and work projects. The controller described explicit project scope,
  no fallback, native delegation and a use-default action.
- The Shaper rejected advertising `--with-api-key` as Kogen's own flag. Native
  authentication remains delegated; the contract does not invent an interactive
  API-key menu or a Kogen authentication-method parser.

## Current explicit approval

The Shaper requested a summary. The controller summarized managed independent
installation/configuration; explicit install/login/update/status; native login
interaction without Kogen-specific authentication-method options; shared default
and optional project login; shape/build preflight; and verified updates affecting
new work while active Builds keep their selected runtime.

The Shaper replied exactly:

> Ok, approved.

This is the same-conversation approval for this revised scope. The controller
then reconciled the maintained package, copied concise probe evidence, added
scenario-linked lifecycle risks and validated structure. The later testing-cost
question was answered with the offline/live split now recorded in questions.md;
no new public behavior or generic testing platform was added.

The package is moved as a whole to Approved only after those checks. This records
approval of an Intent, not implementation success. No new Build is launched by
this approval receipt.
