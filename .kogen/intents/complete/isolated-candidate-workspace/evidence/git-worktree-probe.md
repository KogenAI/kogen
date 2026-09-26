# Linked-worktree topology probe

The probe created `/tmp/kogen-git-topology.2Z5sXv`, initialized a repository, added a linked `kogen/build/probe` worktree, changed a tracked mode, renamed a tracked file, added a symlink and untracked file, exercised locked/foreign/missing-metadata removal, pruned only an explicitly removed owned path, and deleted the disposable root.

Key commands were `git worktree add -b`, `git rev-parse --git-common-dir`, `git rev-parse --git-path index`, `git status --porcelain=v1 -z`, `git worktree lock/remove/unlock/prune`, with lstat-preserving file operations. Exact observed output:

```text
PROBE_ROOT=/tmp/kogen-git-topology.2Z5sXv
CONTROL_HEAD=dfcb6fe5571a29efc77c1e62fe74fc9a6492e083
CANDIDATE_HEAD=dfcb6fe5571a29efc77c1e62fe74fc9a6492e083
CANDIDATE_GIT_FILE=gitdir: /private/tmp/kogen-git-topology.2Z5sXv/control/.git/worktrees/candidate
CANDIDATE_COMMON_DIR=/private/tmp/kogen-git-topology.2Z5sXv/control/.git
CONTROL_GIT_DIR=.git
CONTROL_INDEX=.git/index
CANDIDATE_INDEX=/private/tmp/kogen-git-topology.2Z5sXv/control/.git/worktrees/candidate/index
CANDIDATE_STATUS_HEX=204d206d6f64652e74787400204420747261636b65642e747874003f3f206c696e6b2e747874003f3f206e65772e747874003f3f2072656e616d65642e74787400
CONTROL_STATUS=''
CONTROL_TRACKED=base
LOCKED_REMOVE=refused:fatal: cannot remove a locked working tree, lock reason: probe use 'remove -f -f' to override or unlock first
FOREIGN_REMOVE=refused:fatal: '/tmp/kogen-git-topology.2Z5sXv/foreign' is not a working tree
FOREIGN_SENTINEL=foreign
MISSING_METADATA_REMOVE=refused:fatal: validation failed, cannot remove working tree: '/private/tmp/kogen-git-topology.2Z5sXv/candidate/.git' does not exist
CANDIDATE_EXISTS_AFTER_REFUSAL=yes
REGISTERED_AFTER_PRUNE=0
CLEANUP_EXISTS=no
```

Conclusion: linked worktrees share the common object/ref directory but have separate index/worktree metadata. Ordinary Git refuses the tested locked, foreign, and missing-metadata removals; controller cleanup must preserve those refusals and add its own identity checks rather than force through them.

