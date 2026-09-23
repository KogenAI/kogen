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

    initial =
      Enum.find(histories, fn records ->
        Enum.any?(records, &String.contains?(&1["reason"] || "", "lib/kogen_fake_break.ex"))
      end)

    assert Enum.map(initial, & &1["status"]) |> Enum.take(2) == ["failed", "passed"],
           "a Stop block must continue the same Developer turn until Check passes"

    log = File.read!(Path.join(dest, ".kogen/runtime/fake-harness-log"))
    assert_adapter_transport!(harness, log, developer_session)
  end

  defp assert_adapter_transport!("codex", log, session) do
    assert log =~ "exec resume"
    assert log =~ " #{session} -"
    refute log =~ "claude"
  end

  defp assert_adapter_transport!("claude", log, session) do
    lines = String.split(log, "\n", trim: true)
    argv = Enum.filter(lines, &String.starts_with?(&1, "argv:"))
    launches = Enum.reject(argv, &(&1 =~ "argv: auth status"))
    assert length(launches) == 4
    assert Enum.count(launches, &(&1 =~ "--resume #{session}")) == 1
    assert Enum.count(launches, &(&1 =~ "--session-id #{session}")) == 1
    assert Enum.count(launches, &(&1 =~ "--json-schema")) == 2
    assert Enum.all?(launches, &(&1 =~ "--model claude-opus-5-5 --effort medium"))
    refute log =~ "exec resume"
    refute log =~ "ANTHROPIC_API_KEY=secret"
    assert log =~ "DISABLE_AUTOUPDATER=1"
  end

  defp config(harness) do
    {_fake, developer, reviewer, helper} = @profiles[harness]
    effort = if harness == "claude", do: "medium", else: "low"

    """
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
      ".PHONY: check\ncheck:\n\t@test ! -f lib/kogen_fake_break.ex || { echo 'bounded fixture check: lib/kogen_fake_break.ex remains' >&2; exit 1; }\n"
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
