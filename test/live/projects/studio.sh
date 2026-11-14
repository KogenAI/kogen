# Studio, the heavy-project release journey (docs/live-release-journey.md). A real dependency-heavy
# Elixir/Phoenix project, cloned from its authenticated source at one frozen commit into the run
# folder. Nothing of Studio is vendored into Kogen. Sourcing this file performs no network access.
STUDIO_REVISION=b93ff1d6c0748d74ee410615ed07cafbb7de1f07
if [ -n "${KOGEN_STUDIO_REVISION:-}" ]; then
  if [ -z "${KOGEN_STUDIO_CORPUS_UPDATE:-}" ]; then
    echo "studio: revision override needs KOGEN_STUDIO_CORPUS_UPDATE" >&2
    return 1
  fi
  STUDIO_REVISION=$KOGEN_STUDIO_REVISION
fi
KOGEN_STUDIO_URL=${KOGEN_STUDIO_URL:-git@github.com:KogenAI/studio.git}

if [ -z "${KOGEN_LIVE_RUN_DIR:-}" ]; then
  KOGEN_LIVE_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kogen-real-use-studio.XXXXXX")
fi
mkdir -p "$KOGEN_LIVE_RUN_DIR"
KOGEN_LIVE_RUN_DIR=$(cd "$KOGEN_LIVE_RUN_DIR" && pwd -P)
export KOGEN_LIVE_RUN_DIR

REPO="$KOGEN_LIVE_RUN_DIR/studio-origin"
SLUG=normalize-label-probe
JOURNEY_FILE=lib/studio/kogen_release_probe.ex
INTERRUPT_AFTER=120
# The Intent title becomes a commit subject in a repository whose commit-msg hook may reject names of
# AI products and tools, so the request asks for a title without one.
REQUEST='Add Studio.KogenReleaseProbe.normalize_label/1 in lib/studio/kogen_release_probe.ex. It takes one argument. A binary is trimmed of surrounding whitespace and downcased: when the result is nonempty it returns {:ok, normalized}; a binary that is empty or only whitespace returns {:error, :empty}. Every nonbinary argument, such as nil, an integer or an atom, returns {:error, :invalid_type}. Add project-native ExUnit tests in test/studio/kogen_release_probe_test.exs for mixed case, surrounding whitespace, empty and whitespace-only input, and nonbinary input. This is a reliability probe, not a production feature: do not wire it into any other module, route, page or setting. The Intent title becomes a commit subject in a repository whose commit-msg hook rejects names of AI products and tools, so the title must not name one.'

# Clone the authenticated source into the isolated run folder at the frozen commit. A source that is
# unreadable, a commit that is absent or a different HEAD is a blocked result: never green, never skipped.
prepare_repo() {
  blocked() { echo "studio: blocked: $*" >&2; return 1; }
  [ ! -e "$REPO" ] || { blocked "$REPO already exists"; return 1; }
  # The run's own HOME holds no SSH keys; the source is read with the host's.
  git_home=${real_home:-$HOME}
  clone_err="$KOGEN_LIVE_RUN_DIR/studio-clone.err"
  if ! HOME=$git_home GIT_TERMINAL_PROMPT=0 git clone -q "$KOGEN_STUDIO_URL" "$REPO" 2> "$clone_err"; then
    blocked "cannot read $KOGEN_STUDIO_URL ($(head -c 300 "$clone_err" | tr '\n' ' '))"
    return 1
  fi
  if ! git -C "$REPO" checkout -q -B kogen-live "$STUDIO_REVISION" 2> "$clone_err"; then
    blocked "commit $STUDIO_REVISION is absent from $KOGEN_STUDIO_URL ($(head -c 300 "$clone_err" | tr '\n' ' '))"
    return 1
  fi
  head_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$head_sha" = "$STUDIO_REVISION" ] || { blocked "HEAD $head_sha differs from $STUDIO_REVISION"; return 1; }
  echo "studio: source $KOGEN_STUDIO_URL at $head_sha"
}

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
runner = next(c for c in commands if "KOGEN_ACCEPTANCE_REPORT" in c)
assert '"$KOGEN_NODE"' in runner, "runner must use the installed Node"
assert '--format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"' in runner, "runner paths must stay quoted"
assert "    steps_dir: 'features/steps'" in text, "init selected the wrong steps folder"
PYCONFIG
  # Isolated Hex, Rebar and test data: the run's HOME holds Mix's archives and the daemon home lives
  # under the run folder, never in production or in the source checkout.
  STUDIO_DAEMON_HOME="$KOGEN_LIVE_RUN_DIR/studio-data/daemon"
  mkdir -p "$STUDIO_DAEMON_HOME"
  export STUDIO_DAEMON_HOME
  mix local.hex --force
  mix local.rebar --force
}

verify_without_kogen() {
  mix deps.get
  mix format --check-formatted
  mix test
  # The independent assertion of the requested behavior, not the Build's own tests.
  MIX_ENV=test mix run --no-start -e '
    check = fn input, want ->
      got = Studio.KogenReleaseProbe.normalize_label(input)

      if got != want do
        IO.puts(:stderr, "normalize_label(#{inspect(input)}) = #{inspect(got)}, expected #{inspect(want)}")
        System.halt(1)
      end
    end

    check.("  MiXed Case ", {:ok, "mixed case"})
    check.("   ", {:error, :empty})
    check.("", {:error, :empty})
    check.(nil, {:error, :invalid_type})
    check.(42, {:error, :invalid_type})
    check.(:atom, {:error, :invalid_type})
    IO.puts("normalize_label: independent assertion passed")
  '
}
