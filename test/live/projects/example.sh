# Tiny Tasks (REL-1), the example app in examples/. Builds a fresh local source repository in the
# run folder so each real-use attempt starts from the same ordinary Git baseline. The toolchain comes
# from the app's .tool-versions.
kogen_root=$(cd "$here/../.." && pwd)
example_source="$kogen_root/examples/tiny_tasks"

if [ -z "${KOGEN_LIVE_RUN_DIR:-}" ]; then
  KOGEN_LIVE_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kogen-real-use-example.XXXXXX")
fi
mkdir -p "$KOGEN_LIVE_RUN_DIR"
KOGEN_LIVE_RUN_DIR=$(cd "$KOGEN_LIVE_RUN_DIR" && pwd -P)
export KOGEN_LIVE_RUN_DIR

REPO="$KOGEN_LIVE_RUN_DIR/example-origin"
if [ -e "$REPO" ]; then
  printf 'Example source repository already exists: %s\n' "$REPO" >&2
  exit 1
fi

mkdir -p "$REPO" "$KOGEN_LIVE_RUN_DIR/git-home" \
  "$KOGEN_LIVE_RUN_DIR/empty-template" "$KOGEN_LIVE_RUN_DIR/empty-hooks"
cp -R "$example_source/." "$REPO/"
GIT_CONFIG_GLOBAL="$KOGEN_LIVE_RUN_DIR/git-global-config"
: > "$GIT_CONFIG_GLOBAL"

(
  export HOME="$KOGEN_LIVE_RUN_DIR/git-home"
  export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM=1
  cd "$REPO"
  git -c init.templateDir="$KOGEN_LIVE_RUN_DIR/empty-template" \
    -c core.hooksPath="$KOGEN_LIVE_RUN_DIR/empty-hooks" init -q
  git add -A
  GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' \
    GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' \
    git -c user.name='Kogen Example' \
      -c user.email='kogen-example@example.invalid' \
      -c commit.gpgsign=false \
      -c core.hooksPath="$KOGEN_LIVE_RUN_DIR/empty-hooks" \
      commit -q -m 'Tiny Tasks baseline'
)

SLUG=complete-task
REQUEST='Please extend Tiny Tasks so that a task can be completed without losing the rest of the list. BASE-1: adding a task assigns the next numeric ID and persists it for later commands. BASE-2: plain mix todo.list shows every task in insertion order, one per line as <id> [<status>] <title>, using open for current tasks. TASK-1: add mix todo.complete ID; it changes the identified task from open to done while preserving every task ID, title, insertion position, and other status. A task line uses done for a completed task. TASK-2: add mix todo.list --open; it prints every open task and no done task in insertion order using the same task-line format. Plain mix todo.list continues to show all tasks. You may choose the exact success confirmation shown after a task is completed.'
INTERRUPT_AFTER=60

configure() {
  # Init already chose and checked the commands. This project needs no overrides.
  python3 - <<'PYCONFIG'
import re
text = open(".kogen/project.yaml").read()
commands = [s.replace("''", "'") for s in re.findall(r"run: '((?:[^']|'')*)'", text)]
# The model may respell a detected check of the same name (SET-11); the tool and its job must stay.
checks = {n: r.replace("''", "'") for n, r in re.findall(r"- name: (\S+)\n\s+run: '((?:[^']|'')*)'", text)}
for name, start in [("format", "mix format --check-formatted"), ("compile", "mix compile"), ("test", "mix test")]:
    assert checks.get(name, "").startswith(start), f"init did not select {name}: {start}"
assert checks.get("npm-test") in ("npm test", "npm run test"), "init did not select the npm test script"
assert "    - 'npm ci --no-audit --no-fund'" in text, "init did not select npm setup"
assert "node_modules/@cucumber/cucumber/bin/cucumber.js" in text, "init did not select the project's runner"
runner = next(c for c in commands if "KOGEN_ACCEPTANCE_REPORT" in c)
assert '"$KOGEN_NODE"' in runner, "runner must use the installed Node"
assert '--format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"' in runner, "runner paths must stay quoted"
assert "    steps_dir: 'features/steps'" in text, "init selected the wrong steps folder"
assert "'.formatter.exs'" in text, "init did not protect the formatter"
PYCONFIG
}

verify_without_kogen() {
  npm ci --no-audit --no-fund
  ./node_modules/.bin/cucumber-js --strict --require 'features/steps/*.js' \
    ".kogen/intents/$SLUG/acceptance.feature"
  # The independent feature check (qualified in examples/tiny_tasks-qualification/): accepts any
  # correct implementation, rejects the qualified wrong ones.
  ./node_modules/.bin/cucumber-js --strict --require 'features/steps/*.js' \
    "$kogen_root/examples/tiny_tasks-qualification/acceptance.feature"
  mix format --check-formatted
  mix test --warnings-as-errors
}
