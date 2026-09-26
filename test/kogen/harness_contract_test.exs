defmodule Kogen.HarnessContractTest do
  @moduledoc """
  One Build lifecycle, the same consumer and the same assertions, against both
  harness adapters behind `Kogen.Harness`: the fake Codex and the fake Claude
  Code. Each run fails its first Stop Check, passes it in the same Developer
  session, receives an independent rework verdict, resumes that exact session,
  is accepted by a fresh Reviewer and commits. No provider is contacted.
  """
  use Kogen.IsolatedCase, async: true

  @moduletag timeout: 180_000

  @slug "harness-contract"

  @intent_yaml """
  id: 01960000-0000-7000-8000-0000000c0de5
  slug: #{@slug}
  title: Harness contract
  may_change_guarded_paths:
    - dummy.txt
    - reviewer-rework-marker.txt
  """

  @scenarios_yaml """
  - id: contract-scenario
    given: a fixture Candidate built through the configured harness
    when: Build settles Check, Review and rework
    then: dummy.txt contains reviewed fixture value and the Build commits
    wrong_result: the adapter drops a Stop block, resumes another session, or commits the unreviewed value
    verified_by: [check]
    evidence: fake harness lifecycle
    proof:
      offline: [proof.txt]
      paid_target: none
      paid_reason: "offline-sufficient: scripted lifecycle fixture drives both adapters"
      affected_paths: [dummy.txt, reviewer-rework-marker.txt]
  """

  @profiles %{
    "codex" => {"fake_codex", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"},
    "claude" => {"fake_claude", "claude-opus-5-5", "claude-opus-5-5", "claude-sonnet-5"}
  }

  for harness <- ["codex", "claude"] do
    test "the #{harness} adapter settles Stop, Review, exact resume and Commit through one Build" do
      run_contract!(unquote(harness))
    end
  end

  # schema-free-developer-turns: a fresh and a resumed Build Developer turn
  # carry no handoff schema on either adapter, on argv or stdin; the settled
  # turn's final message, empty, prose or malformed, passes through verbatim
  # as notes with a matching digest; and a provider-failure control (a
  # nonzero exit) still fails the turn.
  for harness <- ["codex", "claude"] do
    test "the #{harness} adapter's Build Developer turns carry no schema and pass the final message through as notes" do
      schema_free_developer_turns!(unquote(harness))
    end
  end

  test "any other harness name is rejected before Build launches anything" do
    dest = fixture!("codex")

    File.write!(
      Path.join(dest, ".kogen/config.yaml"),
      String.replace(config("codex"), "harness: codex", "harness: opencode")
    )

    commit_all!(dest)
    System.put_env("KOGEN_HARNESS", Path.join(File.cwd!(), "test/support/fake_codex"))

    assert {:error, "unsupported harness: opencode; expected codex or claude"} =
             File.cd!(dest, fn -> Kogen.Build.run(@slug) end)

    refute File.exists?(Path.join(dest, ".kogen/runtime/fake-harness-log"))
  end

  test "the Developer and Reviewer prompts keep main's full placeholder set" do
    developer = File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/developer.md"))
    reviewer = File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/reviewer.md"))

    developer_placeholders = [
      "{{intent_title}}",
      "{{intent_id}}",
      "{{approved_path}}",
      "{{may_change_guarded_paths}}",
      "{{verification_ownership}}",
      "{{readiness_commands}}",
      "{{execution_policy}}"
    ]

    reviewer_placeholders = [
      "{{intent_title}}",
      "{{intent_id}}",
      "{{approved_path}}",
      "{{candidate_id}}",
      "{{execution_policy}}"
    ]

    for placeholder <- developer_placeholders, do: assert(developer =~ placeholder)
    for placeholder <- reviewer_placeholders, do: assert(reviewer =~ placeholder)

    rendered_developer =
      Enum.reduce(developer_placeholders, developer, fn placeholder, acc ->
        String.replace(acc, placeholder, "x", global: true)
      end)

    rendered_reviewer =
      Enum.reduce(reviewer_placeholders, reviewer, fn placeholder, acc ->
        String.replace(acc, placeholder, "x", global: true)
      end)

    refute rendered_developer =~ "{{"
    refute rendered_reviewer =~ "{{"
  end

  for {label, keys, expected} <- [
        {"missing harness", [], "harness selection has no harness; expected codex or claude"},
        {"blank harness", [harness: ""], "unsupported harness: \"\"; expected codex or claude"},
        {"unknown harness pi", [harness: "pi"],
         "unsupported harness: \"pi\"; expected codex or claude"}
      ] do
    test "Harness.open refuses a selection with #{label} before any launch" do
      config = Map.new(unquote(Macro.escape(keys)))
      assert {:error, unquote(expected)} = Kogen.Harness.open(config)
    end
  end

  for {label, keys, expected} <- [
        {"a context without harness", [],
         "harness selection has no harness; expected codex or claude"},
        {"a context naming an unknown harness", [harness: "pi"],
         "unsupported harness: \"pi\"; expected codex or claude"}
      ] do
    test "every launch function raises loudly given #{label}" do
      context = Map.new(unquote(Macro.escape(keys)))
      expected = unquote(expected)

      assert_raise ArgumentError, expected, fn ->
        Kogen.Harness.launch_developer("p", "m", "e", [], context)
      end

      assert_raise ArgumentError, expected, fn ->
        Kogen.Harness.resume_developer("s", "p", "m", "e", [], context)
      end

      assert_raise ArgumentError, expected, fn ->
        Kogen.Harness.launch_build_developer("p", "m", "e", [], context)
      end

      assert_raise ArgumentError, expected, fn ->
        Kogen.Harness.launch_reviewer("p", "m", "e", context)
      end

      assert_raise ArgumentError, fn ->
        Kogen.Harness.launch_context(context)
      end
    end
  end

  test "a nil launch context raises rather than silently resolving to Codex" do
    nil_context = Enum.random([nil])

    assert_raise ArgumentError, fn ->
      Kogen.Harness.launch_developer("p", "m", "e", [], nil_context)
    end

    assert_raise ArgumentError, fn ->
      Kogen.Harness.launch_reviewer("p", "m", "e", nil_context)
    end
  end

  test "a Codex selection and its launch context carry harness codex explicitly" do
    dir =
      Path.join(System.tmp_dir!(), "kogen-codex-explicit-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    original = System.get_env("KOGEN_HARNESS")

    on_exit(fn ->
      if original,
        do: System.put_env("KOGEN_HARNESS", original),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    System.put_env("KOGEN_HARNESS", Path.join(File.cwd!(), "test/support/fake_codex"))

    assert {:ok, selection} = Kogen.Harness.open(%{harness: "codex"}, dir)
    assert selection.harness == "codex"
    context = Kogen.Harness.launch_context(selection)
    assert context.harness == "codex"
  end

  test "KOGEN_HARNESS only replaces the executable of a claude route, never selecting Codex" do
    dir =
      Path.join(System.tmp_dir!(), "kogen-claude-override-#{System.unique_integer([:positive])}")

    claude_root = Path.join(dir, "claude")
    File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
    on_exit(fn -> File.rm_rf(dir) end)

    for name <- ["KOGEN_HARNESS", "KOGEN_CLAUDE_ROOT"] do
      original = System.get_env(name)

      on_exit(fn ->
        if original, do: System.put_env(name, original), else: System.delete_env(name)
      end)
    end

    fake = Path.join(File.cwd!(), "test/support/fake_claude")
    System.put_env("KOGEN_HARNESS", fake)
    System.put_env("KOGEN_CLAUDE_ROOT", claude_root)

    {:ok, config} = Kogen.Intent.read_config(".kogen/config.yaml", "claude")
    assert {:ok, selection} = Kogen.Harness.open(config, dir)
    assert selection.harness == "claude"
    context = Kogen.Harness.launch_context(selection)
    assert context.harness == "claude"
    assert context.executable == fake

    # A Codex-only entry point refuses the Claude route instead of adopting it.
    assert {:error, "Kogen Codex requires a codex route, got harness: \"claude\""} =
             Kogen.Codex.open(config, dir)
  end

  test "selected-route-only validation and readiness: an unselected pi or unproven route never blocks the selected route",
       ctx do
    _ = ctx

    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-selected-route-only-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, ".kogen/config.yaml")

    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping:   {model: gpt-5.6-sol, effort: low}
        developer: {model: gpt-5.6-sol, effort: low}
        reviewer:  {model: gpt-5.6-terra, effort: medium}
        helpers:
          scout:  {model: gpt-5.6-luna, effort: low}
          worker: {model: gpt-5.6-luna, effort: medium}
          expert: {model: gpt-5.6-sol, effort: medium}
      future:
        harness: pi
        shaping:   {model: pi-1, effort: low}
        developer: {model: pi-1, effort: low}
        reviewer:  {model: pi-1, effort: low}
        helpers:
          scout:  {model: pi-1, effort: low}
          worker: {model: pi-1, effort: low}
          expert: {model: pi-1, effort: low}
      unproven:
        harness: claude
        shaping:   {model: claude-unproven-9, effort: low}
        developer: {model: claude-unproven-9, effort: low}
        reviewer:  {model: claude-unproven-9, effort: low}
        helpers:
          scout:  {model: claude-unproven-9, effort: low}
          worker: {model: claude-unproven-9, effort: low}
          expert: {model: claude-unproven-9, effort: low}
    outer_resumptions: 2
    verification_retries: 2
    """)

    # The default (selected) route resolves and readies successfully, without
    # ever validating the broken unselected routes.
    assert {:ok, config} = Kogen.Intent.read_config(path)
    assert config.harness == "codex"

    original = System.get_env("KOGEN_HARNESS")

    on_exit(fn ->
      if original,
        do: System.put_env("KOGEN_HARNESS", original),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    System.put_env("KOGEN_HARNESS", Path.join(File.cwd!(), "test/support/fake_codex"))
    assert {:ok, selection} = Kogen.Harness.open(config, dir)
    assert selection.harness == "codex"

    # Selecting the unsupported-harness route fails loudly with today's message.
    assert {:error, "unsupported harness: pi; expected codex or claude"} =
             Kogen.Intent.read_config(path, "future")

    # Selecting the unproven-model route fails with the proven-model message,
    # naming the role.
    assert {:error, reason} = Kogen.Intent.read_config(path, "unproven")
    assert reason =~ "unsupported Claude Code model for shaping: claude-unproven-9"
  end

  defp schema_free_developer_turns!(harness) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-schema-free-#{harness}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    context = developer_fixture_context!(harness, dir)

    # A fresh turn with no final agent message settles with empty notes and no
    # schema argument or pasted schema block anywhere in argv or stdin.
    System.put_env("FAKE_MESSAGE_MODE", "absent")

    assert {:ok, fresh} =
             Kogen.Harness.launch_build_developer("PROMPT", model(harness), "medium", [], context)

    fresh_args = argv_lines(dir)
    refute Enum.any?(fresh_args, &(&1 =~ "schema"))
    assert File.read!(Path.join(dir, "stdin")) == "PROMPT"
    assert fresh.message == ""
    assert fresh.invocation_evidence.message_sha256 == sha256("")
    refute Map.has_key?(fresh.invocation_evidence, :schema)
    refute Map.has_key?(fresh.invocation_evidence, :schema_sha256)

    # A resumed turn, whose final message is prose, keeps the exact session,
    # carries no schema and passes the prose through verbatim as notes.
    prose = "Rework applied; nothing further to declare."
    System.put_env("FAKE_MESSAGE_MODE", "present")
    System.put_env("FAKE_MESSAGE", prose)

    assert {:ok, resumed} =
             Kogen.Harness.resume_build_developer(
               fresh.session_id,
               "FEEDBACK",
               model(harness),
               "medium",
               [],
               context
             )

    resumed_args = argv_lines(dir)
    refute Enum.any?(resumed_args, &(&1 =~ "schema"))
    assert File.read!(Path.join(dir, "stdin")) == "FEEDBACK"
    assert resumed.session_id == fresh.session_id
    assert resumed.message == prose
    assert resumed.invocation_evidence.message_sha256 == sha256(prose)

    # A provider-failure control (a nonzero exit) still fails the turn closed.
    System.put_env("FAKE_EXIT", "1")

    assert {:error, {:developer_transport_failure, _reason, failure_evidence}} =
             Kogen.Harness.launch_build_developer("p", model(harness), "medium", [], context)

    assert failure_evidence.outcome == :provider_failure
  after
    System.delete_env("FAKE_MESSAGE_MODE")
    System.delete_env("FAKE_MESSAGE")
    System.delete_env("FAKE_EXIT")
    System.delete_env("FAKE_SESSION")
  end

  defp model("codex"), do: "gpt-5.6-sol"
  defp model("claude"), do: "claude-opus-5-5"

  defp argv_lines(dir),
    do: dir |> Path.join("argv") |> File.read!() |> String.split("\n", trim: true)

  defp sha256(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp developer_fixture_context!("codex", dir) do
    executable = Path.join(dir, "codex")

    File.write!(executable, """
    #!/bin/sh
    set -eu
    d="#{dir}"
    : > "$d/argv"; for a in "$@"; do printf '%s\\n' "$a" >> "$d/argv"; done
    input="$(cat)"; printf '%s' "$input" > "$d/stdin"
    is_resume=0; previous=; penultimate=; last=
    for a in "$@"; do
      [ "$a" = resume ] && is_resume=1
      previous="$a"; penultimate="$last"; last="$a"
    done
    resume_id=; [ "$is_resume" -eq 1 ] && resume_id="$penultimate"
    if [ "${FAKE_EXIT:-0}" != 0 ]; then exit "${FAKE_EXIT}"; fi
    sid="${resume_id:-${FAKE_SESSION:-dev-session-1}}"
    printf '{"type":"thread.started","thread_id":"%s"}\\n' "$sid"
    if [ "${FAKE_MESSAGE_MODE:-absent}" = present ]; then
      python3 -c 'import json, os; print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": os.environ.get("FAKE_MESSAGE", "")}}))'
    fi
    printf '{"type":"turn.completed","thread_id":"%s"}\\n' "$sid"
    """)

    File.chmod!(executable, 0o755)
    %{harness: "codex", executable: executable, args: [], env: []}
  end

  defp developer_fixture_context!("claude", dir) do
    executable = Path.join(dir, "claude")

    File.write!(executable, """
    #!/bin/sh
    set -eu
    d="#{dir}"
    : > "$d/argv"; for a in "$@"; do printf '%s\\n' "$a" >> "$d/argv"; done
    if [ "$1" = -p ]; then cat > "$d/stdin"; else cat >/dev/null; fi
    session=; previous=
    for a in "$@"; do
      [ "$previous" = --session-id ] && session="$a"
      [ "$previous" = --resume ] && session="$a"
      previous="$a"
    done
    [ -n "${FAKE_SESSION:-}" ] && session="$FAKE_SESSION"
    if [ "${FAKE_EXIT:-0}" != 0 ]; then exit "${FAKE_EXIT}"; fi
    message=""
    [ "${FAKE_MESSAGE_MODE:-absent}" = present ] && message="${FAKE_MESSAGE:-}"
    python3 -c 'import json, sys; emit = lambda e: print(json.dumps({**e, "session_id": sys.argv[1]})); emit({"type": "system", "subtype": "init"}); emit({"type": "result", "subtype": "success", "is_error": False, "terminal_reason": "completed", "result": sys.argv[2]})' "$session" "$message"
    """)

    File.chmod!(executable, 0o755)

    config = %{
      harness: "claude",
      helpers: %{
        scout: %{model: "claude-sonnet-5", effort: "low"},
        worker: %{model: "claude-sonnet-5", effort: "medium"},
        expert: %{model: "claude-opus-5-5", effort: "high"}
      }
    }

    %{harness: "claude", executable: executable, args: [], env: [], config: config, project: dir}
  end

  defp run_contract!(harness) do
    {fake, _developer, _reviewer, _helper} = @profiles[harness]
    dest = fixture!(harness)
    commit_all!(dest)
    head_before = git!(dest, ["rev-parse", "HEAD"])

    claude_root = Path.join(dest <> "-claude-root", "claude")
    File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)
    System.put_env("KOGEN_CLAUDE_ROOT", claude_root)
    System.put_env("KOGEN_HARNESS", Path.join(File.cwd!(), "test/support/#{fake}"))
    System.delete_env("KOGEN_ROLE")
    raw_log_dir = Path.join(Path.dirname(claude_root), "raw")
    System.put_env("KOGEN_RAW_LOG_DIR", raw_log_dir)

    assert :ok = File.cd!(dest, fn -> Kogen.Build.run(@slug) end)

    assert git!(dest, ["show", "HEAD:dummy.txt"]) == "reviewed fixture value"
    assert git!(dest, ["rev-parse", "HEAD^"]) == head_before
    evidence = File.read!(Path.join(dest, ".kogen/intents/complete/#{@slug}/evidence.md"))
    assert evidence =~ "Outer resumptions used: 1"
    assert evidence =~ "Reviewer verdict: accept"
    assert File.read!(Path.join(dest, ".kogen/runtime/fake-reviewer-calls")) == "2\n"

    [developer_session] =
      Regex.run(~r/Developer session id: `([^`]+)`/, evidence, capture: :all_but_first)

    [reviewer_session] =
      Regex.run(~r/Reviewer session id: `([^`]+)`/, evidence, capture: :all_but_first)

    assert reviewer_session != developer_session

    histories =
      (Path.wildcard(Path.join(raw_log_dir, "verification-history-*.jsonl")) ++
         [Path.join(dest, ".kogen/runtime/verification-history.jsonl")])
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      end)

    assert Enum.all?(List.flatten(histories), &(&1["session_id"] == developer_session))

    # The controller-owned Verification Record and history are the only
    # place a failed-then-passed cycle pair is retained: the first cycle
    # fails at the ignored `kogen_fake_break` marker, and the controller
    # resumes the exact same Developer session to settle a passing cycle,
    # before Jev, Review and Commit ever run.
    initial =
      Enum.find(histories, fn records ->
        Enum.any?(records, &String.contains?(&1["reason"] || "", "kogen_fake_break"))
      end)

    assert Enum.map(initial, & &1["status"]) |> Enum.take(2) == ["failed", "passed"],
           "the controller must resume the same Developer session until verification passes"

    log = File.read!(Path.join(dest, ".kogen/runtime/fake-harness-log"))
    assert_adapter_transport!(harness, log, developer_session)
  end

  defp assert_adapter_transport!("codex", log, session) do
    # Two resumes of the exact Developer session: the controller's
    # verification resume (fixing the ignored `kogen_fake_break` marker) and
    # the Reviewer's one outer-rework resume.
    resumes = log |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "exec resume"))
    assert length(resumes) == 2
    assert Enum.all?(resumes, &(&1 =~ " #{session} -"))
    refute log =~ "claude"
    refute log =~ "KOGEN_VERIFICATION_CONTEXT"
  end

  defp assert_adapter_transport!("claude", log, session) do
    lines = String.split(log, "\n", trim: true)
    argv = Enum.filter(lines, &String.starts_with?(&1, "argv:"))
    launches = Enum.reject(argv, &(&1 =~ "argv: auth status"))
    # Fresh Developer, the controller's verification resume of that same
    # session, the rework Reviewer, the outer-rework resume of that same
    # session, and the accepting Reviewer: five non-auth launches with two
    # `--resume` calls naming the exact Developer session.
    assert length(launches) == 5
    assert Enum.count(launches, &(&1 =~ "--resume #{session}")) == 2
    assert Enum.count(launches, &(&1 =~ "--session-id #{session}")) == 1
    assert Enum.count(launches, &(&1 =~ "--json-schema")) == 2
    assert Enum.all?(launches, &(&1 =~ "--model claude-opus-5-5 --effort medium"))
    refute log =~ "exec resume"
    refute log =~ "ANTHROPIC_API_KEY=secret"
    assert log =~ "DISABLE_AUTOUPDATER=1"
    env = Enum.filter(lines, &String.starts_with?(&1, "env:"))
    assert env != []
    assert Enum.all?(env, &(&1 =~ "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1 "))
    refute log =~ "KOGEN_VERIFICATION_CONTEXT"
  end

  defp config(harness) do
    {_fake, developer, reviewer, helper} = @profiles[harness]
    effort = if harness == "claude", do: "medium", else: "low"

    """
    default_route: #{harness}
    routes:
      #{harness}:
        harness: #{harness}
        shaping:   {model: #{developer}, effort: #{effort}}
        developer: {model: #{developer}, effort: #{effort}}
        reviewer:  {model: #{reviewer}, effort: medium}
        helpers:
          scout:  {model: #{helper}, effort: low}
          worker: {model: #{helper}, effort: medium}
          expert: {model: #{developer}, effort: high}
    outer_resumptions: 2
    verification_retries: 2
    """
  end

  defp fixture!(harness) do
    source = File.cwd!()

    dest =
      Path.join(
        System.tmp_dir!(),
        "kogen-contract-#{harness}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    for relative <- [
          ".codex/hooks.json",
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md",
          "priv/kogen/prompts/execution-policy.md"
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dest, relative)))
      File.cp!(Path.join(source, relative), Path.join(dest, relative))
    end

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)
    File.mkdir_p!(Path.join(dest, "lib"))
    File.write!(Path.join(dest, "lib/.keep"), "")
    File.write!(Path.join(dest, "proof.txt"), "focused fixture selector\n")

    File.write!(
      Path.join(dest, "Makefile"),
      ".PHONY: check\ncheck:\n\t@test ! -f .kogen/runtime/kogen_fake_break || { echo 'bounded fixture check: kogen_fake_break remains' >&2; exit 1; }\n"
    )

    File.write!(Path.join(dest, "priv/kogen/verification_targets.yaml"), """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture
    """)

    File.write!(Path.join(dest, ".gitignore"), ".kogen/build.lock\n.kogen/runtime/\n")
    File.mkdir_p!(Path.join(dest, ".kogen"))
    File.write!(Path.join(dest, ".kogen/config.yaml"), config(harness))

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @scenarios_yaml)

    File.write!(
      Path.join(intent_dir, "requirement.json"),
      ~s({"path":"dummy.txt","expected":"reviewed fixture value"})
    )

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    dest
  end

  defp commit_all!(dest) do
    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
