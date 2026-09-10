defmodule Kogen.VerificationOwnershipLifecycleTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build

  @slug "owned-gates"

  test "Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework" do
    dir = fixture!()
    prior_harness = System.get_env("KOGEN_HARNESS")
    prior_raw_log_dir = System.get_env("KOGEN_RAW_LOG_DIR")
    System.put_env("KOGEN_HARNESS", Path.join(dir, "fake-codex"))
    System.put_env("KOGEN_RAW_LOG_DIR", Path.join(dir, ".kogen/runtime/archives"))

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")

      if prior_raw_log_dir,
        do: System.put_env("KOGEN_RAW_LOG_DIR", prior_raw_log_dir),
        else: System.delete_env("KOGEN_RAW_LOG_DIR")

      File.rm_rf(dir)
    end)

    assert :ok = File.cd!(dir, fn -> Build.run(@slug) end)

    assert File.read!(Path.join(dir, ".kogen/runtime/owner.log"))
           |> String.split("\n", trim: true) == [
             "stop:check",
             "stop:check",
             "outer:gate_one",
             "outer:gate_two",
             "stop:check",
             "outer:gate_one",
             "outer:gate_two",
             "outer:gate_three",
             "review:1",
             "stop:check",
             "outer:gate_one",
             "outer:gate_two",
             "outer:gate_three",
             "review:2"
           ]

    launch = File.read!(Path.join(dir, ".kogen/runtime/developer-launch-prompt"))
    resume = File.read!(Path.join(dir, ".kogen/runtime/developer-resume-prompts"))

    for prompt <- [launch, resume] do
      assert prompt =~ "make check"
      assert prompt =~ "make live"
      assert prompt =~ "make gate_one"
      assert prompt =~ "make gate_two"
      assert prompt =~ ".codex/hooks/check.sh"
      assert prompt =~ "early signal"
      assert prompt =~ "delegated helpers"
      assert prompt =~ "Focused non-gate tests remain allowed"
    end

    assert File.read!(Path.join(dir, ".kogen/runtime/policy-env")) ==
             "[\"check\",\"live\",\"gate_one\",\"gate_two\",\"gate_three\"]\n"

    denied = File.read!(Path.join(dir, ".kogen/runtime/policy-denials"))
    assert denied =~ ~r/helper:.*Kogen machinery owns verification gates/
    assert denied =~ ~r/post-review:.*Kogen machinery owns verification gates/
    assert denied =~ "focused non-gate tests"
    refute File.exists?(Path.join(dir, ".kogen/runtime/prohibited-dispatch-marker"))

    archive_paths =
      Path.wildcard(Path.join(dir, ".kogen/runtime/archives/verification-history-*.jsonl"))
      |> Enum.sort_by(&history_sequence!/1)

    history =
      (archive_paths ++ [Path.join(dir, ".kogen/runtime/verification-history.jsonl")])
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        path
        |> File.stream!()
        |> Enum.map(&(String.trim(&1) |> Jason.decode!()))
      end)

    assert Enum.map(history, & &1["status"]) == ["failed", "passed", "passed", "passed"]
    refute Enum.any?(history, &(&1["candidate"] == "stale-candidate"))
  end

  defp history_sequence!(path) do
    [sequence] =
      Regex.run(~r/verification-history-\d+-(\d+)\.jsonl$/, Path.basename(path),
        capture: :all_but_first
      )

    String.to_integer(sequence)
  end

  defp fixture! do
    root = Path.expand("../..", __DIR__)
    dir = Path.join(System.tmp_dir!(), "kogen-owned-gates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".codex/hooks"))
    File.mkdir_p!(Path.join(dir, "priv/kogen/prompts"))

    for file <- ["check.sh", "verification_policy.py"] do
      File.cp!(Path.join(root, ".codex/hooks/#{file}"), Path.join(dir, ".codex/hooks/#{file}"))
    end

    File.cp!(Path.join(root, ".codex/hooks.json"), Path.join(dir, ".codex/hooks.json"))

    for file <- ["developer.md", "reviewer.md"] do
      File.cp!(
        Path.join(root, "priv/kogen/prompts/#{file}"),
        Path.join(dir, "priv/kogen/prompts/#{file}")
      )
    end

    File.write!(Path.join(dir, ".gitignore"), ".kogen/runtime/\n.kogen/build.lock\n")

    File.write!(
      Path.join(dir, ".kogen/config.yaml") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      config()
    )

    File.write!(Path.join(dir, "Makefile"), makefile())

    File.cp!(
      Path.join(root, "test/support/scenario_response.py"),
      Path.join(dir, "scenario_response.py")
    )

    File.write!(Path.join(dir, "fake-codex"), harness())
    File.chmod!(Path.join(dir, "fake-codex"), 0o755)

    intent_dir = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), intent())
    File.write!(Path.join(intent_dir, "scenarios.yaml"), scenarios())

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "baseline"], cd: dir, env: git_env())
    dir
  end

  defp intent do
    """
    id: 01960000-0000-7000-8000-00000000cafe
    slug: #{@slug}
    title: Owned gates
    may_change_guarded_paths:
      - dummy.txt
    """
  end

  defp scenarios do
    """
    - id: first
      given: a settled Check
      when: outer verification starts
      then: gate one runs
      wrong_result: no ownership
      verified_by: [check, gate_one]
      evidence: fixture
    - id: second
      given: a settled Check
      when: outer verification continues
      then: gate two runs once
      wrong_result: duplicate gate one
      verified_by: [gate_two, gate_one, gate_three]
      evidence: fixture
    """
  end

  defp config do
    """
    harness: codex
    shaping:   {model: fake, effort: low}
    developer: {model: fake, effort: low}
    reviewer:  {model: fake, effort: low}
    helpers:
      scout:  {model: fake, effort: low}
      worker: {model: fake, effort: medium}
      expert: {model: fake, effort: medium}
    outer_resumptions: 4
    """
  end

  defp makefile do
    """
    .PHONY: check gate_one gate_two gate_three
    check:
    \t@mkdir -p .kogen/runtime
    \t@echo stop:check >> .kogen/runtime/owner.log
    \t@test ! -f .kogen/runtime/fail-check
    gate_one:
    \t@echo outer:gate_one >> .kogen/runtime/owner.log
    gate_two:
    \t@mkdir -p .kogen/runtime; echo outer:gate_two >> .kogen/runtime/owner.log; n=0; test -f .kogen/runtime/gate-two-count && n=$$(cat .kogen/runtime/gate-two-count); n=$$((n + 1)); echo $$n > .kogen/runtime/gate-two-count; test $$n -gt 1
    gate_three:
    \t@echo outer:gate_three >> .kogen/runtime/owner.log
    """
  end

  defp harness do
    """
    #!/bin/sh
    set -eu
    mkdir -p .kogen/runtime
    response_helper="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/scenario_response.py"
    input="$(cat)"
    reviewer=0; resume=0; previous=; output_file=
    for arg in "$@"; do
      [ "$arg" = --output-schema ] && reviewer=1
      [ "$arg" = resume ] && resume=1
      [ "$previous" = --output-last-message ] && output_file="$arg"
      previous="$arg"
    done
    if [ "$reviewer" -eq 1 ]; then
      n=0; test -f .kogen/runtime/reviews && n=$(cat .kogen/runtime/reviews); n=$((n + 1)); echo $n > .kogen/runtime/reviews
      echo review:$n >> .kogen/runtime/owner.log
      if [ "$n" -eq 1 ]; then verdict=rework; else verdict=accept; fi
      printf '%s' "$input" | python3 "$response_helper" reviewer "$verdict" > "$output_file"
      printf '{"type":"thread.started","thread_id":"review-%s"}\n{"type":"turn.completed","thread_id":"review-%s"}\n' "$n" "$n"
      exit 0
    fi
    if [ "$resume" -eq 1 ]; then
      printf '%s\n' "$input" >> .kogen/runtime/developer-resume-prompts
      n=0; test -f .kogen/runtime/resume-calls && n=$(cat .kogen/runtime/resume-calls); n=$((n + 1)); echo $n > .kogen/runtime/resume-calls
      if [ "$n" -eq 1 ]; then
        printf '%s\n' '{"candidate":"stale-candidate","status":"passed","target":"check","session_id":"dev-1","exit_code":0}' > .kogen/runtime/verification.json
      elif [ "$n" -eq 2 ]; then
        :
      fi
    else
      printf '%s\n' "$input" > .kogen/runtime/developer-launch-prompt
      n=0
    fi
    printf '%s\n' "$KOGEN_VERIFICATION_TARGETS" > .kogen/runtime/policy-env
    printf '%s\n' '{"type":"thread.started","thread_id":"dev-1"}'
    if [ "$resume" -eq 0 ]; then
      touch .kogen/runtime/fail-check
      printf '%s' '{"session_id":"dev-1"}' | sh .codex/hooks/check.sh >/dev/null
      rm .kogen/runtime/fail-check
      printf '%s' '{"session_id":"dev-1"}' | sh .codex/hooks/check.sh >/dev/null
    elif [ "$n" -gt 2 ]; then
      context=helper; [ "$n" -ge 4 ] && context=post-review
      printf '%s' '{"tool_name":"Bash","tool_input":{"command":"make gate_one"}}' | python3 .codex/hooks/verification_policy.py > .kogen/runtime/policy-output
      if grep -q permissionDecision .kogen/runtime/policy-output; then
        printf '%s:' "$context" >> .kogen/runtime/policy-denials
        cat .kogen/runtime/policy-output >> .kogen/runtime/policy-denials
      else
        touch .kogen/runtime/prohibited-dispatch-marker
      fi
      printf '%s' '{"session_id":"dev-1"}' | sh .codex/hooks/check.sh >/dev/null
    fi
    response="$(printf '%s' "$input" | python3 "$response_helper" developer)"
    printf '{"type":"item.completed","item":{"type":"agent_message","text":%s}}\n' "$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    printf '%s\n' '{"type":"turn.completed","thread_id":"dev-1"}'
    """
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]
  end
end
