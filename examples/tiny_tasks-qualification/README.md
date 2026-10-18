# Tiny Tasks acceptance qualification

Run the qualification from this directory. `npm ci` needs the npm registry unless your npm
cache already holds the pinned packages (`--prefer-offline` uses it); everything else runs offline.

```sh
sh qualify.sh
```

The script starts from a clean copy of `../tiny_tasks`, installs the Cucumber packages pinned in the lockfile, and runs format, ExUnit, and the bridge feature five times.
It then applies each patch to a fresh copy and runs
[acceptance.feature](acceptance.feature) through the same step bridge. The three
deliberately incorrect patches must fail at their contract assertion (the exact, ordered task list);
the correct reference patch must pass. No generated implementation is compared
with the reference.

| File | Purpose |
| --- | --- |
| `acceptance.feature` | Independent check of TASK-1 and TASK-2 |
| `wrong-ignore-old-data.patch` | Completion drops tasks other than the selected one |
| `wrong-filter-direction.patch` | The `--open` option selects done tasks |
| `wrong-reverse-order.patch` | Completion reverses the stored order |
| `reference.patch` | One correct implementation of the request |
| `qualify.sh` | Reproducible baseline reliability and mutation qualification |
