# Publication and recovery probe

The disposable repository created a Candidate commit containing both accepted source and `.kogen/intents/complete/probe/intent.yaml`. Publication used Git's compare-and-swap primitive:

```sh
git update-ref refs/heads/main "$accepted" "$admitted"
```

It first supplied a deliberately wrong old ref, then the admitted ref, then repeated the stale transition. It retained a locked crash-leftover worktree/branch, verified ordinary cleanup refusal, then explicitly unlocked and removed only the known owned resources.

```text
ADMITTED=419f50e52c0d0473844294deb2f48aac4126c1b1
ACCEPTED=c54c2234aac203e7b77d7ee6ec4406fe2960963e
ACCEPTED_TREE=d06619609e3187adeb5a2cf17b51fcf8e3f346d8
PRE_PUBLISH_MAIN=419f50e52c0d0473844294deb2f48aac4126c1b1
PRECONDITION_FAILURE=isolated:fatal: update_ref failed for ref 'refs/heads/main': cannot lock ref 'refs/heads/main': is at 419f50e52c0d0473844294deb2f48aac4126c1b1 but expected deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
MAIN_AFTER_FAILED_PRECONDITION=419f50e52c0d0473844294deb2f48aac4126c1b1
MAIN_AFTER_CAS=c54c2234aac203e7b77d7ee6ec4406fe2960963e
MAIN_TREE=d06619609e3187adeb5a2cf17b51fcf8e3f346d8
MAIN_APP=accepted
MAIN_COMPLETE=id: probe
REPEAT=refused-stale-owner:fatal: update_ref failed for ref 'refs/heads/main': cannot lock ref 'refs/heads/main': is at c54c2234aac203e7b77d7ee6ec4406fe2960963e but expected 419f50e52c0d0473844294deb2f48aac4126c1b1
CRASH_LEFTOVER_BRANCH=c54c2234aac203e7b77d7ee6ec4406fe2960963e
CRASH_LEFTOVER_LOCK=crash-leftover
SAFE_CLEANUP=refused-locked:fatal: cannot remove a locked working tree, lock reason: crash-leftover use 'remove -f -f' to override or unlock first
MAIN_STILL_ACCEPTED=c54c2234aac203e7b77d7ee6ec4406fe2960963e
OWNED_CLEANUP_WORKTREE_EXISTS=no
OWNED_CLEANUP_BRANCH_EXISTS=no
CLEANUP_EXISTS=no
```

The probe establishes local Git ref atomicity and useful refusal controls. It does not by itself prove Kogen's future orchestration or crash recovery; focused fault-injection scenarios retain that burden.

