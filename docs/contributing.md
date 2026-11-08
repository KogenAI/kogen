# Contributing

## Development
Set up once from a plain clone, with the toolchain from `.tool-versions` (Go and Node) on `PATH`. The component modules in `cli/go.mod` are public Go modules on github.com/KogenAI and need no setup:

```sh
git clone https://github.com/KogenAI/kogen
cd kogen
(cd spec && npm ci)
(cd test/acceptance && npm ci)
```

Checks for an ordinary change, as [docs/testing-strategy.md](testing-strategy.md) describes (the tests a change needs follow [docs/testing-rules.md](testing-rules.md)):

```sh
(cd cli && go test -race ./...)                # Go tests: unit and integration, against real git in temp repos
(cd spec && sh check.sh)                       # the specification's own checks
sh packaging/package.sh                        # the release the scenarios install (they use the newest in dist/)
(cd test/acceptance && npx cucumber-js --strict --tags "not @live" --require "steps/*.js" --require "support/*.js" ../../spec/features/04-building.feature)   # the chapter you changed
```

Release checks:

```sh
sh test/suite.sh                               # every deterministic layer and scenario; run on macOS and Linux
sh test/live/real-use.sh example file://$PWD/dist/<archive>   # real use on the example app (REL-1)
KOGEN_LIVE_CREDENTIALS='kogen provider login claude-code < <token file>' sh test/live/real-use.sh example file://$PWD/dist/<archive>   # the same on the Claude Code route, unattended (REL-1)
sh test/live/self-repo.sh /tmp/kogen-self && KOGEN_SELF_REPO=/tmp/kogen-self sh test/live/real-use.sh kogen file://$PWD/dist/<archive>   # installed self-hosting qualification attempt (REL-1)
sh test/live/self-build-check.sh <run folder>/project      # REL-3 on what that run landed; real-use.sh prints the run folder
sh examples/tiny_tasks-qualification/qualify.sh               # qualifies the example app's own checks
```

During development, fix Kogen directly with an external coding agent when needed. Self-hosting is a qualification path, not a prerequisite for repairing the tool. Preserve failed-attempt evidence and verify the candidate independently. An uncommitted development build is not a qualified release; the release checks above still apply.

The scenarios run Python from `.tool-versions`; set `KOGEN_TEST_PYTHON_BIN` to use another Python 3.13. Read `sh test/suite.sh` layer timings for the actual scope and host load; focused checks remain the development loop.
