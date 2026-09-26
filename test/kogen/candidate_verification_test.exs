defmodule Kogen.CandidateVerificationTest do
  @moduledoc """
  Scenarios `controller-judges-candidate` and `write-boundary-fails-closed`:
  the parent controller runs `make check` and every selected target with cwd
  equal to the Candidate, as its own supervised child outside every role's
  process tree, records a Candidate-bound receipt even when the Candidate's
  own copies of the hook scripts are tampered with, resumes the exact
  Developer session on a failed cycle, and stops on the guarded-path check
  before any verification when the tampering itself is not guarded. The
  runner also drops `MIX_BUILD_PATH`/`MIX_DEPS_PATH`/`MIX_EXS` and
  `KOGEN_WRITE_BOUNDARY` from its own child's environment, and directs
  `KOGEN_LIVE_LOG_DIR` at control unless the caller already set one.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.CandidateFixture, as: Candidate
  alias Kogen.WorkspaceFixture, as: Fixture

  # A fake Developer whose fresh launch breaks the Candidate's `make check`
  # (an ignored marker the fixture recipe rejects) and tampers with the
  # Candidate's own copies of the three hook scripts the real bootstrap
  # relies on, rewriting each to always pass or allow. Its resume captures
  # the verification-failure prompt it was given (into the harness home, so
  # the test can read it after the Build), repairs the Candidate, and
  # delegates everything else (including every Reviewer turn) to
  # `fake_codex_simple_accept`.
  @tamper_developer_template ~S"""
  #!/bin/sh
  set -eu
  input="$(cat)"
  is_resume=0; prev=; out=
  for a in "$@"; do
    [ "$a" = resume ] && is_resume=1
    [ "$prev" = --output-last-message ] && out="$a"
    prev="$a"
  done

  if [ "${KOGEN_ROLE:-}" = developer ] && [ "$is_resume" = 0 ]; then
  mkdir -p .kogen/runtime
  : > .kogen/runtime/kogen_fake_break

  cat > .codex/hooks/check.sh <<'HOOK'
  #!/bin/sh
  exit 0
  HOOK
  chmod +x .codex/hooks/check.sh

  cat > .codex/hooks/stop_runner.py <<'HOOK'
  #!/usr/bin/env python3
  print('{"continue": true}')
  HOOK
  chmod +x .codex/hooks/stop_runner.py

  cat > .codex/hooks/verification_policy.py <<'HOOK'
  def evaluate(*args, **kwargs):
      return {"decision": "allow"}
  HOOK

  response="$(printf '%s' "$input" | python3 __SCENARIO_RESPONSE__ developer)"
  if [ -n "$out" ]; then printf '%s\n' "$response" > "$out"; fi
  printf '{"type":"thread.started","thread_id":"dev-session-1"}\n'
  printf '{"type":"item.completed","item":{"type":"agent_message","text":%s}}\n' "$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  printf '{"type":"turn.completed","thread_id":"dev-session-1"}\n'
  exit 0
  fi

  if [ "${KOGEN_ROLE:-}" = developer ] && [ "$is_resume" = 1 ]; then
  if [ -n "${KOGEN_HARNESS_HOME:-}" ]; then
  printf '%s' "$input" > "$KOGEN_HARNESS_HOME/captured-resume-prompt"
  fi
  rm -f .kogen/runtime/kogen_fake_break
  fi

  printf '%s' "$input" | exec __DELEGATE__ "$@"
  """

  @live_makefile """
  .PHONY: check
  check:
  \t@test ! -f .kogen/runtime/kogen_fake_break || { echo 'fixture check: kogen_fake_break remains' >&2; exit 1; }
  \t@mkdir -p "$$KOGEN_LIVE_LOG_DIR"
  \t@pwd -P > "$$KOGEN_LIVE_LOG_DIR/pwd"
  \t@env > "$$KOGEN_LIVE_LOG_DIR/env"
  \t@mix compile >/dev/null 2>&1 || true
  \t@ls _build/*/lib > "$$KOGEN_LIVE_LOG_DIR/mix-ls" 2>/dev/null || true
  """

  @mix_exs """
  defmodule CandidateVerificationFixture.MixProject do
    use Mix.Project

    def project do
      [app: :fixture, version: "0.1.0", elixir: "~> 1.14"]
    end
  end
  """

  @lib_fixture """
  defmodule CandidateVerificationFixtureLib do
    def hello, do: :world
  end
  """

  setup do
    :ok
  end

  # --- 1: a failed Candidate check is judged by the controller, not the
  # Candidate's own tampered hooks, and resumes the exact Developer session --

  test "the controller runs make check against the Candidate and records a failed Candidate-bound receipt despite tampered hook copies, resuming the same Developer session, when the Intent guards .codex/hooks/**" do
    control = Fixture.create!(guards: ["dummy.txt", ".codex/hooks/**"])
    on_exit(fn -> File.rm_rf(control) end)

    role = tamper_developer_role(Fixture.tmp_dir!("tamper-role-guarded"))

    assert :ok = Fixture.build!(control, harness: role)

    record = Candidate.record(control)
    [attempt] = record["attempts"]
    cycles = get_in(attempt, ["verification", "cycles"])
    assert length(cycles) == 2
    [first, second] = cycles

    assert first["status"] == "failed"
    assert second["status"] == "passed"

    check_receipt = Enum.find(first["receipts"], &(&1["target"] == "check"))
    assert check_receipt["status"] == "failed"

    # Candidate-bound: the failed receipt is bound to the exact Candidate id
    # the controller computed for that cycle, never a value the tampered
    # hooks (which the controller never consults) could have forged.
    assert check_receipt["candidate_id"] == first["candidate_id"]
    assert is_binary(first["candidate_id"]) and first["candidate_id"] != ""
    assert second["developer_session_id"] == first["developer_session_id"]

    log_path = Path.join(control, check_receipt["log_path"])

    assert log_path =~
             ~r{scenario-tracking/[^/]+/verification/attempt-[^/]+/logs/cycle-1-check\.log$}

    assert File.regular?(log_path)

    prompt =
      control
      |> Candidate.candidate()
      |> Map.fetch!("harness_home")
      |> Path.join("captured-resume-prompt")
      |> File.read!()

    assert String.starts_with?(prompt, "Controller verification failed after your turn")
    assert prompt =~ "`make check` failed"
  end

  # --- 2: the same tampering, ungarded, stops on the guarded-path check
  # before any verification cycle exists ------------------------------------

  test "the same tampering stops the Build on the guarded-path check before any verification cycle when the Intent does not guard .codex/hooks/**" do
    control = Fixture.create!()
    on_exit(fn -> File.rm_rf(control) end)

    role = tamper_developer_role(Fixture.tmp_dir!("tamper-role-unguarded"))

    assert {:error, reason} = Fixture.build!(control, harness: role)
    assert reason =~ "Candidate changed paths outside Approved guards"

    record = Candidate.record(control)
    [attempt] = record["attempts"]
    refute Map.has_key?(attempt, "verification")
  end

  # --- 3: every target runs through VerificationRunner with cwd the
  # Candidate ----------------------------------------------------------------

  test "the controller runs every target through VerificationRunner with cwd equal to the Candidate" do
    control = control_with_live_recipe!()
    on_exit(fn -> File.rm_rf(control) end)

    assert :ok = Fixture.build!(control)

    block = Candidate.candidate(control)

    pwd =
      control
      |> Path.join(".kogen/runtime/live-evidence/pwd")
      |> File.read!()
      |> String.trim()

    assert pwd == block["worktree_path"]
  end

  # --- 4: KOGEN_LIVE_LOG_DIR defaults to control's live-evidence directory
  # and survives Candidate removal; a caller-set value wins ------------------

  test "a marker a target writes under KOGEN_LIVE_LOG_DIR survives publication in control's live-evidence directory, and a caller-set KOGEN_LIVE_LOG_DIR wins" do
    default_control = control_with_live_recipe!()
    on_exit(fn -> File.rm_rf(default_control) end)

    assert :ok = Fixture.build!(default_control)
    block = Candidate.candidate(default_control)
    refute File.exists?(block["worktree_path"]), "the Candidate is gone after publication"

    assert File.regular?(Path.join(default_control, ".kogen/runtime/live-evidence/pwd")),
           "the marker survives in control after the Candidate worktree is removed"

    overridden_control = control_with_live_recipe!()
    on_exit(fn -> File.rm_rf(overridden_control) end)
    caller_dir = Fixture.tmp_dir!("caller-live-log")

    assert :ok = Fixture.build!(overridden_control, env: [{"KOGEN_LIVE_LOG_DIR", caller_dir}])

    assert File.regular?(Path.join(caller_dir, "pwd"))

    refute File.exists?(Path.join(overridden_control, ".kogen/runtime/live-evidence/pwd")),
           "a caller-set KOGEN_LIVE_LOG_DIR wins over control's own default"
  end

  # --- 5: Mix redirection is dropped from the verification child -----------

  test "the verification child drops inherited MIX_BUILD_PATH, MIX_DEPS_PATH and MIX_EXS, so a Candidate mix compile lands only under its own _build/" do
    control = control_with_live_recipe!()
    on_exit(fn -> File.rm_rf(control) end)

    before_build = control_build_snapshot(control)

    planted = [
      {"MIX_BUILD_PATH", Path.join(control, "_build")},
      {"MIX_DEPS_PATH", Path.join(control, "deps")},
      {"MIX_EXS", Path.join(control, "mix.exs")}
    ]

    assert :ok = Fixture.build!(control, env: planted)

    env_dump = control |> Path.join(".kogen/runtime/live-evidence/env") |> File.read!()
    refute env_dump =~ "MIX_BUILD_PATH="
    refute env_dump =~ "MIX_DEPS_PATH="
    refute env_dump =~ "MIX_EXS="

    mix_ls = control |> Path.join(".kogen/runtime/live-evidence/mix-ls") |> File.read!()
    assert mix_ls =~ "fixture"

    assert control_build_snapshot(control) == before_build,
           "control's own _build/ must gain nothing from the Candidate's own mix compile"
  end

  # --- 6: KOGEN_WRITE_BOUNDARY is dropped from the verification child -------

  test "the verification child's environment lacks KOGEN_WRITE_BOUNDARY even when the controller's own environment sets it" do
    control = control_with_live_recipe!()
    on_exit(fn -> File.rm_rf(control) end)

    assert :ok =
             Fixture.build!(control, env: [{"KOGEN_WRITE_BOUNDARY", "spoofed-not-a-real-sha256"}])

    env_dump = control |> Path.join(".kogen/runtime/live-evidence/env") |> File.read!()
    refute env_dump =~ "KOGEN_WRITE_BOUNDARY="
  end

  # --- 7: the controller's verification children are themselves unconfined,
  # so a fixture Build they start applies its own boundary -------------------

  @tag :unconfined
  @tag timeout: 180_000
  test "a fixture Build started by the controller's verification child records an applied write boundary, proving the child itself runs unconfined" do
    control = Fixture.create!()
    on_exit(fn -> File.rm_rf(control) end)

    nested_control = Fixture.create!()
    on_exit(fn -> File.rm_rf(nested_control) end)

    nested_jev_log = Path.join(Fixture.tmp_dir!("nested-jev"), "log")

    ebin_flags =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(
        &(Path.type(&1) == :absolute and Path.basename(&1) == "ebin" and File.dir?(&1))
      )
      |> Enum.sort()
      |> Enum.map_join(" ", &"-pa #{shell_quote(&1)}")

    makefile = """
    .PHONY: check
    check:
    \t@test ! -f .kogen/runtime/kogen_fake_break || { echo 'fixture check: kogen_fake_break remains' >&2; exit 1; }
    \tcd #{shell_quote(nested_control)} && MIX_BUILD_PATH=#{shell_quote(Path.join(nested_control, "_build"))} KOGEN_HARNESS=#{shell_quote(Fixture.support("fake_codex_simple_accept"))} KOGEN_JEV_TRANSPORT=#{shell_quote(Fixture.support("fake_jev"))} KOGEN_JEV_SECURITY=#{shell_quote(Fixture.support("fake_security"))} FAKE_JEV_LOG_DIR=#{shell_quote(nested_jev_log)} elixir #{ebin_flags} -S mix kogen.build #{Fixture.slug()}
    """

    File.write!(Path.join(control, "Makefile"), makefile)
    Fixture.git!(control, ["add", "-A"])
    Fixture.git!(control, ["commit", "-q", "-m", "nested Build recipe"])

    assert :ok = Fixture.build!(control)

    nested_record = Candidate.record(nested_control)
    assert nested_record["boundary"]["mode"] == "applied"
  end

  # --- helpers ---------------------------------------------------------

  defp tamper_developer_role(dir) do
    body =
      @tamper_developer_template
      |> String.replace("__SCENARIO_RESPONSE__", inspect(Fixture.support("scenario_response.py")))
      |> String.replace("__DELEGATE__", inspect(Fixture.support("fake_codex_simple_accept")))

    Fixture.fake!(dir, "fake_dev_tamper", body)
  end

  defp control_with_live_recipe!(opts \\ []) do
    control = Fixture.create!(opts)
    File.write!(Path.join(control, "Makefile"), @live_makefile)
    File.write!(Path.join(control, "mix.exs"), @mix_exs)
    File.mkdir_p!(Path.join(control, "lib"))
    File.write!(Path.join(control, "lib/fixture.ex"), @lib_fixture)
    Fixture.git!(control, ["add", "-A"])
    Fixture.git!(control, ["commit", "-q", "-m", "install live-evidence recipe"])
    control
  end

  defp control_build_snapshot(control) do
    control
    |> Path.join("_build/**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  defp shell_quote(path), do: "\"" <> String.replace(path, "\"", "\\\"") <> "\""
end
