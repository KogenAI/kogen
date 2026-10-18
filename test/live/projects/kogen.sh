# Kogen itself (REL-2, REL-3). REPO is a disposable repository holding the candidate source with
# an ordinary Git baseline (its commits are test data), made with test/live/self-repo.sh.
REPO=${KOGEN_SELF_REPO:?set KOGEN_SELF_REPO to the disposable repository made by test/live/self-repo.sh}
SLUG=unreadable-login
# Commit-msg hooks often reject messages that name an AI product or tool, so the request asks for
# a title without one.
REQUEST='When the saved ChatGPT login (~/.kogen/credentials/chatgpt.json) cannot be read, kogen provider list should say so and tell the user to sign in again, instead of reporting an internal error. The Intent title becomes a commit subject in a repository whose commit-msg hook rejects names of AI products and tools, so the title must not name one.'
INTERRUPT_AFTER=120

configure() {
  python3 - <<'PYCONFIG'
import re
p = ".kogen/project.yaml"
s = open(p).read()
commands = [v.replace("''", "'") for v in re.findall(r"run: '((?:[^']|'')*)'", s)]
# The model may respell a detected check of the same name (SET-11); the tool and its job must stay.
checks = {n: r.replace("''", "'") for n, r in re.findall(r"- name: (\S+)\n\s+run: '((?:[^']|'')*)'", s)}
for name, start in [("format", "mix format --check-formatted"), ("compile", "mix compile"), ("test", "mix test")]:
    assert checks.get(name, "").startswith(start), f"init did not select {name}: {start}"
assert "    - 'mix deps.get'" in s, "init did not select Mix setup"
assert '$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js' in s, "init did not select the bundled runner"
runner = next(c for c in commands if "KOGEN_ACCEPTANCE_REPORT" in c)
assert '"$KOGEN_NODE"' in runner, "runner must use the installed Node"
assert '--format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"' in runner, "runner paths must stay quoted"
assert "    steps_dir: 'features/steps'" in s, "init selected the wrong steps folder"
assert "'.formatter.exs'" in s, "init did not protect the formatter"
# Self-build Intents use their own step folder, separate from the product's acceptance suite.
s = s.replace("features/steps", "test/intents/steps")
for command in ["cd test/acceptance && npm ci --silent --no-audit --no-fund", "cd spec && npm ci --silent --no-audit --no-fund"]:
    if command.split(" --")[0] not in s:
        s = s.replace("  fix:", "    - '" + command + "'\n  fix:", 1)
for name, command in [("self-go", "cd cli && go test -race ./..."), ("self-spec", "cd spec && sh check.sh")]:
    if command not in commands:
        s = s.replace("  acceptance:", "    - {name: " + name + ", run: '" + command + "'}\n  acceptance:", 1)
open(p, "w").write(s)
PYCONFIG
  mkdir -p test/intents/steps
  printf 'Cucumber step definitions for Kogen self-build Intents.\n' > test/intents/steps/README.md
}

verify_without_kogen() {
  NODE_PATH=test/acceptance/node_modules test/acceptance/node_modules/.bin/cucumber-js --strict --require 'test/intents/steps/*.js' ".kogen/intents/$SLUG/acceptance.feature" && mix compile --warnings-as-errors && mix test && (cd cli && go test -race ./...) && (cd spec && sh check.sh)
}
