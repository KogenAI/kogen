# Admission receipt

Command run from `/Users/almirsarajcic/Areas/Kogen/kogen`:

```sh
git branch --show-current
git rev-parse HEAD
git status --porcelain=v1 --untracked-files=all
test -d .kogen/intents/complete/rehearsed-verification-plan && echo COMPLETE_PACKAGE_PRESENT
```

Observed output:

```text
main
7c7c3426c61c80753043d51766f53ba877c22674
COMPLETE_PACKAGE_PRESENT
```

The blank line between HEAD and the package marker is the empty porcelain result. All four handoff admission conditions passed before this Draft was created.

