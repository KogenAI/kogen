# Second failed Build: controller/hook lifetime mismatch

Historical Build `w67S8G8_0CycmVcYgTaZdIC1` stopped on outer attempt 1 with `verification settlement integrity failure: unified verification produced no bound settlement`.

[Retained observations](observations.json) preserve the runtime record digest, exact controller-owned context snapshots, observed directory entries, and hashes of the inspected unaccepted source copies. Attempt 0 reached Review; attempt 1 has context but no state or history file. Both contexts declare unified schema version 1 but omit history_path. The inspected replacement hook requires history_path and initialized state before dispatch. The replacement initializer on disk supplies all three; the emitted context does not.

This supports a mixed-generation diagnosis: the running controller emitted the earlier protocol while the replacement hook required the later one. It is not an exact dump of the loaded controller or a retained native Stop response; the final record proves missing settlement, and source/context inspection explains the incompatible prerequisite. Cloudflare warnings do not establish this failure's cause. No fresh passing Build or repaired combined-route proof is claimed.

The earlier recommendation to bypass the clean-worktree check was wrong: this run began from an unaccepted intermediate implementation, outside the contract's accepted-baseline transition. Do not repair this by treating absent unified state as initial state, downgrading unified context to legacy, changing historical records, or granting extra attempts.

Inspection used JSON decoding of the named record/context files, directory enumeration, and reads of lib/kogen/build/verification.ex and .codex/hooks/stop_runner.py. No provider session or gate was launched for this diagnosis. Original runtime artifacts remain untouched. General refresh belongs to the separately parked same-build-refresh investigation.
