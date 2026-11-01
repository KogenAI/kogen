# Acceptance liveness observation measurements

Scope: only the three affected scenarios, three fresh processes/worlds per side.
No complete-suite timing claim is made. Each command installed the same existing
release archive into a new temporary prefix; scenario homes, repositories and
servers were fresh. No readiness or check-result cache was used. Runs were
sequential on the same host; a brief local regression development run overlapped
candidate repetition 2, so host load is not perfectly controlled.

Host: Darwin 25.6.0, arm64, Apple T6041; Node v24.21.0, Cucumber 13.3.0,
Go 1.27.2, Python 3.13.16, Git 2.54.0. Both sides used release
`dist/kogen-d0f37d7d-darwin-arm64.tar.gz`, SHA-256
`1e42a88cd0a466ec9b2875daa36533e12925154e0414ed03495570567b2d7102`.
Baseline HEAD `d0f37d7d5c7ca8afb6b19a6d9c8ac6d5488865af`, tree
`7067f6b8945e4230d2309a6d0ca5d25de65f3ad5`, handler blob
`12bc15f93dd4b3a9b9434fb9159b630d9d2b593b`. Candidate uses the same HEAD;
the measured tracked tree with only the handler change over HEAD is
`ff119286da5ba1c00279a915dd4a2a21ff78f045`, handler blob
`ce3234ee444fb9b624e68243f74e3e1d0e0d7379`. The approved untracked
acceptance package and evidence/test files are not included in these tracked
identities. Baseline runs preceded the handler edit.

Reproduce from repository root on each corresponding source state (use
`baseline` then `candidate` for side); each command launches a fresh Cucumber:

```sh
side=baseline # candidate after handler edit
mkdir -p docs/evidence/k-acceptance-fixed-wait
for r in 1 2 3; do
  for item in '04-building:105' '08-chatgpt:84' '09-cli-and-process:287'; do
    name=${item%:*}; line=${item#*:}
    out="../../docs/evidence/k-acceptance-fixed-wait/$side-$r-$name"
    (cd test/acceptance && npx cucumber-js --strict --require 'steps/*.js' --require 'support/*.js' --format "json:$out.json" "../../spec/features/$name.feature:$line") > "docs/evidence/k-acceptance-fixed-wait/$side-$r-$name.log" 2>&1
    status=$?
    echo "exit=$status" >> "docs/evidence/k-acceptance-fixed-wait/$side-$r-$name.log"
  done
done
```

Raw Cucumber JSON (step durations in nanoseconds) and console output with exit
status are retained in `docs/evidence/k-acceptance-fixed-wait/`. The elapsed
column is the Cucumber summary wall time for each single-scenario invocation,
including its hooks; the liveness and signal columns are measured Cucumber
step contributions, not estimates. Signal is shown only for the group-signal
scenario. Moving the wait means its contribution shifts from liveness to
signal; the total still includes that meaningful negative-observation interval.
There are three liveness uses: six seconds per execution of all three was the
nominal old padding, not a measured aggregate. The retained two seconds observes
that a process-group SIGINT does not cancel the Build; sending a signal alone
cannot establish that negative result.

| Side | Run | Scenario | Wall s | Liveness s | Group signal s | Failures |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| baseline | 1 | 04-building | 42.601 | 2.005728 | — | 0 |
| baseline | 1 | 08-chatgpt | 6.164 | 2.001803 | — | 0 |
| baseline | 1 | 09-cli-and-process | 18.224 | 2.002191 | 0.000188292 | 0 |
| baseline | 2 | 04-building | 49.053 | 2.000350 | — | 0 |
| baseline | 2 | 08-chatgpt | 6.686 | 2.002349 | — | 0 |
| baseline | 2 | 09-cli-and-process | 14.489 | 2.009564 | 0.000115832 | 0 |
| baseline | 3 | 04-building | 46.719 | 2.002798 | — | 0 |
| baseline | 3 | 08-chatgpt | 5.651 | 2.002807 | — | 0 |
| baseline | 3 | 09-cli-and-process | 10.910 | 2.013663 | 0.000136375 | 0 |
| candidate | 1 | 04-building | 43.727 | 0.000137 | — | 0 |
| candidate | 1 | 08-chatgpt | 3.934 | 0.000695 | — | 0 |
| candidate | 1 | 09-cli-and-process | 10.031 | 0.000080 | 2.000759915 | 0 |
| candidate | 2 | 04-building | 36.311 | 0.000098 | — | 0 |
| candidate | 2 | 08-chatgpt | 5.719 | 0.000774 | — | 0 |
| candidate | 2 | 09-cli-and-process | 17.115 | 0.000153 | 2.013860832 | 0 |
| candidate | 3 | 04-building | 72.083 | 0.000210 | — | 0 |
| candidate | 3 | 08-chatgpt | 7.498 | 0.000729 | — | 0 |
| candidate | 3 | 09-cli-and-process | 22.376 | 0.000178 | 2.001512833 | 0 |

Affected-only aggregate of the three wall times per repetition (seconds):

| Side | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| baseline | 66.989 | 70.228 | 63.280 |
| candidate | 57.692 | 59.145 | 101.957 |
