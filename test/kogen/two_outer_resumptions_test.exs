defmodule Kogen.TwoOuterResumptionsTest do
  @moduledoc """
  Scenario "two-outer-resumptions-then-stop": a Developer whose Candidate
  keeps failing Review. The third non-accepting outcome must stop the
  Build with a reason, create no Commit, and consume exactly two
  `Codex resume` launches (never a third).

  Runs `Kogen.Build.run/1` in-process against a minimal fixture repo (no
  real Elixir/mix project needed here: `make check` in the fixture is a
  trivial always-passing target, since this test is about resumption
  counting, not about `make check` itself, which the full lifecycle test
  in test/kogen/lifecycle_test.exs already exercises for real).
  """
  use Kogen.IsolatedCase, async: true

  @slug "always-rework-intent"

  @intent_yaml """
  id: 01960000-0000-7000-8000-00000000a1ea
  slug: #{@slug}
  title: Always rework intent
  may_change_guarded_paths:
    - dummy.txt
  """

  @scenarios_yaml """
  - id: fake-scenario
    given: a fake Candidate
    when: the fake Reviewer always answers rework
    then: the Build stops after two outer resumptions
    wrong_result: a third resume happens, or a Commit is made
    verified_by: [check]
    evidence: fake Reviewer scripted to answer rework three times
    proof:
      offline: [proof.txt]
      paid_target: none
      paid_reason: "offline-sufficient: scripted lifecycle fixture observes resumption accounting"
      affected_paths: [dummy.txt]
  """

  @config_yaml """
  default_route: codex
  routes:
    codex:
      harness: codex
      shaping:   {model: fake, effort: low}
      developer: {model: fake, effort: low}
      reviewer:  {model: fake, effort: low}
      helpers:
        scout:  {model: fake, effort: low}
        worker: {model: fake, effort: medium}
        expert: {model: fake, effort: medium}
  outer_resumptions: 2
  verification_retries: 2
  """

  @claude_config_yaml """
  default_route: claude
  routes:
    claude:
      harness: claude
      shaping:   {model: claude-opus-5-5, effort: medium}
      developer: {model: claude-opus-5-5, effort: medium}
      reviewer:  {model: claude-opus-5-5, effort: medium}
      helpers:
        scout:  {model: claude-sonnet-5, effort: low}
        worker: {model: claude-sonnet-5, effort: medium}
        expert: {model: claude-opus-5-5, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  @makefile """
  .PHONY: check
  check:
  \t@true
  """

  test "stops after two outer resumptions when Review never accepts" do
    stops_after_two_resumptions!("codex")
  end

  test "stops after two outer resumptions when Claude Code Review never accepts" do
    stops_after_two_resumptions!("claude")
  end

  # Scenario `missing-proof-selector-is-unfinished`: a declared offline proof
  # selector still missing after every settled attempt is unfinished work. It
  # never reaches Review, spends each outer resumption, then stops.
  test "a declared proof selector missing on every attempt spends the outer resumptions without Review" do
    stops_after_two_resumptions!("codex", :missing_selector)
  end

  @missing_selector "test/kogen/never_written_test.exs"

  defp stops_after_two_resumptions!(harness, mode \\ :review) do
    project_root = File.cwd!()
    dest = Path.join(System.tmp_dir!(), "kogen-rework-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    File.mkdir_p!(Path.join(dest, ".codex/hooks"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/check.sh"),
      Path.join(dest, ".codex/hooks/check.sh")
    )

    File.cp!(
      Path.join(project_root, ".codex/hooks/stop_runner.py"),
      Path.join(dest, ".codex/hooks/stop_runner.py")
    )

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)

    File.cp!(
      Path.join(project_root, ".codex/hooks/environment.py"),
      Path.join(dest, ".codex/hooks/environment.py")
    )

    File.cp!(Path.join(project_root, ".codex/hooks.json"), Path.join(dest, ".codex/hooks.json"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/verification_policy.py"),
      Path.join(dest, ".codex/hooks/verification_policy.py")
    )

    File.mkdir_p!(Path.join(dest, "priv/kogen/prompts"))

    for prompt <- ["developer.md", "reviewer.md", "execution-policy.md"] do
      File.cp!(
        Path.join(project_root, "priv/kogen/prompts/#{prompt}"),
        Path.join(dest, "priv/kogen/prompts/#{prompt}")
      )
    end

    File.write!(Path.join(dest, "Makefile"), @makefile)
    File.write!(Path.join(dest, "proof.txt"), "focused fixture selector\n")
    File.mkdir_p!(Path.join(dest, "priv/kogen"))

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

    File.write!(
      Path.join(dest, ".kogen/config.yaml") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      if(harness == "claude", do: @claude_config_yaml, else: @config_yaml)
    )

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)

    {intent_yaml, scenarios_yaml} = contract_yaml(mode)
    File.write!(Path.join(intent_dir, "intent.yaml"), intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), scenarios_yaml)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)

    head_before = git!(dest, ["rev-parse", "HEAD"])

    fake_harness =
      if harness == "claude",
        do: Path.join(project_root, "test/support/fake_claude"),
        else: Path.join(project_root, "test/support/fake_codex_always_rework")

    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    if harness == "claude" do
      claude_root = Path.join(dest <> "-claude", "claude")
      File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
      on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)
      System.put_env("KOGEN_CLAUDE_ROOT", claude_root)
      System.put_env("FAKE_CLAUDE_REVIEW", "rework")
      System.put_env("FAKE_CLAUDE_STOP_BLOCK", "0")
      System.put_env("FAKE_CLAUDE_RESUME_EDITS", "0")
    end

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    result =
      File.cd!(dest, fn ->
        Kogen.Build.run(@slug)
      end)

    assert {:error, reason} = result
    assert reason =~ "stopped after 2 outer resumptions"

    assert_mode_outcome!(mode, dest, reason)

    head_after = git!(dest, ["rev-parse", "HEAD"])
    assert head_after == head_before, "no Commit should have been made"

    refute File.dir?(Path.join(dest, ".kogen/intents/complete/#{@slug}"))
    assert File.dir?(intent_dir), "the approved Intent directory must be left as-is"
    refute File.exists?(Path.join(dest, ".kogen/build.lock")), "the lock must be released"

    log_lines =
      Path.join(dest, ".kogen/runtime/fake-harness-log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "argv:"))
      |> Enum.reject(&String.starts_with?(&1, "argv: auth status"))

    resume_marker = if harness == "claude", do: " --resume ", else: "exec resume"
    resume_calls = Enum.count(log_lines, &String.contains?(&1, resume_marker))

    reviewer_calls =
      dest
      |> Path.join(".kogen/runtime/fake-reviewer-calls")
      |> File.read()
      |> reviewer_call_count()
      |> String.trim()
      |> String.to_integer()

    assert resume_calls == 2,
           "expected exactly two Codex resume launches, log:\n#{Enum.join(log_lines, "\n")}"

    assert reviewer_calls == expected_reviews(mode),
           "expected exactly three Reviewer launches (all rework), log:\n#{Enum.join(log_lines, "\n")}"

    assert_output_paths!(harness, mode, log_lines)
  end

  defp contract_yaml(:review), do: {@intent_yaml, @scenarios_yaml}

  defp contract_yaml(:missing_selector) do
    {@intent_yaml <> "  - #{@missing_selector}\n",
     @scenarios_yaml
     |> String.replace("offline: [proof.txt]", "offline: [#{@missing_selector}]")
     |> String.replace(
       "affected_paths: [dummy.txt]",
       "affected_paths: [dummy.txt, #{@missing_selector}]"
     )}
  end

  defp assert_mode_outcome!(:missing_selector, dest, reason),
    do: assert_unfinished_work!(dest, reason)

  defp assert_mode_outcome!(:review, _dest, _reason), do: :ok

  defp expected_reviews(:missing_selector), do: 0
  defp expected_reviews(:review), do: 3

  defp assert_output_paths!("codex", :review, log_lines),
    do: assert_owned_output_paths!(log_lines)

  defp assert_output_paths!(_harness, _mode, _log_lines), do: :ok

  defp reviewer_call_count({:ok, calls}), do: calls
  defp reviewer_call_count({:error, :enoent}), do: "0"

  defp assert_unfinished_work!(dest, reason) do
    assert reason =~
             "stopped after 2 outer resumptions without an accepting Review: Unfinished work: missing declared proof selector #{@missing_selector}"

    refute File.exists?(Path.join(dest, ".kogen/runtime/fake-reviewer-calls")),
           "unfinished work never reaches Review"

    [record_path] =
      Path.wildcard(Path.join(dest, ".kogen/runtime/scenario-tracking/*/record.json"))

    attempts = record_path |> File.read!() |> Jason.decode!() |> Map.fetch!("attempts")
    assert Enum.map(attempts, & &1["outcome"]) == List.duplicate("unfinished_work", 3)
  end

  defp assert_owned_output_paths!(log_lines) do
    # Developer turns (fresh and resumed) carry no handoff schema and own no
    # output file; only each Reviewer owns its verdict output.
    {reviewer_lines, developer_lines} =
      Enum.split_with(log_lines, &String.contains?(&1, " --output-last-message "))

    assert length(developer_lines) == 3
    assert length(reviewer_lines) == 3
    refute Enum.any?(developer_lines, &String.contains?(&1, "--output-schema"))

    output_paths =
      Enum.map(reviewer_lines, fn line ->
        [_before, path | _after] = String.split(line, " --output-last-message ")
        path |> String.split(" ") |> List.first()
      end)

    assert Enum.uniq(output_paths) == output_paths,
           "every Reviewer invocation must own a distinct output path"

    assert Enum.all?(output_paths, &(not File.exists?(&1))),
           "owned invocation output paths must be cleaned after handled completion"
  end

  # Scenario `build-records-and-holds-route`: a Build started on a non-default
  # route survives a mid-Build edit of .kogen/config.yaml (models changed, the
  # default route changed, then the selected route removed entirely) after the
  # first Developer launch. Every later launch (the resumed Developer, the
  # Reviewer) and the frozen tracking-record route must still reflect the
  # originally resolved route, and the committed build-summary.json/evidence.md
  # must name it.
  @route_slug "route-holding-intent"

  @route_intent_yaml """
  id: 01960000-0000-7000-8000-00000000b0b1
  slug: #{@route_slug}
  title: Route holding intent
  may_change_guarded_paths:
    - dummy.txt
    - reviewer-rework-marker.txt
    - .kogen/config.yaml
  """

  @route_scenarios_yaml """
  - id: route-holding-scenario
    given: a fake Candidate
    when: the fake Reviewer reworks once then accepts
    then: every launch and the tracking record use the originally resolved route
    wrong_result: a later launch or the recorded route reflects a mid-Build config edit
    verified_by: [check]
    evidence: fake harness scripted to rework once then accept, with a mid-Build config mutation hook
    proof:
      offline: [proof.txt]
      paid_target: none
      paid_reason: "offline-sufficient: scripted lifecycle fixture observes route freezing"
      affected_paths: [dummy.txt, reviewer-rework-marker.txt]
  """

  @route_config_before """
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
    other:
      harness: codex
      shaping:   {model: gpt-other-shape, effort: medium}
      developer: {model: gpt-other-dev, effort: medium}
      reviewer:  {model: gpt-other-review, effort: high}
      helpers:
        scout:  {model: gpt-other-scout, effort: low}
        worker: {model: gpt-other-worker, effort: medium}
        expert: {model: gpt-other-expert, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  # After the first Developer launch: the selected route's models change, the
  # default route changes to the (about-to-be-removed) selected route, and the
  # selected route is then removed entirely. If the Build ever re-read config,
  # this alone would make every later step fail (unknown route "other") rather
  # than merely use different values.
  # First edit (after the fresh Developer turn): the selected route's models
  # change and default_route moves back to codex.
  @route_config_edited """
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
    other:
      harness: codex
      shaping:   {model: gpt-mutated-shape, effort: low}
      developer: {model: gpt-mutated-dev, effort: low}
      reviewer:  {model: gpt-mutated-review, effort: low}
      helpers:
        scout:  {model: gpt-mutated-scout, effort: low}
        worker: {model: gpt-mutated-worker, effort: low}
        expert: {model: gpt-mutated-expert, effort: low}
  outer_resumptions: 2
  verification_retries: 2
  """

  # Second edit (after the resumed Developer turn): the selected route is gone.
  @route_config_after """
  default_route: other
  routes:
    codex:
      harness: codex
      shaping:   {model: gpt-5.6-sol, effort: low}
      developer: {model: gpt-mutated-dev, effort: low}
      reviewer:  {model: gpt-mutated-review, effort: medium}
      helpers:
        scout:  {model: gpt-5.6-luna, effort: low}
        worker: {model: gpt-5.6-luna, effort: medium}
        expert: {model: gpt-5.6-sol, effort: medium}
  outer_resumptions: 2
  verification_retries: 2
  """

  test "a Build on a non-default route holds its frozen route across a mid-Build config edit, recording and publishing it" do
    project_root = File.cwd!()
    dest = Path.join(System.tmp_dir!(), "kogen-route-hold-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    File.mkdir_p!(Path.join(dest, ".codex/hooks"))

    for hook <- ~w(check.sh stop_runner.py environment.py verification_policy.py) do
      File.cp!(
        Path.join(project_root, ".codex/hooks/#{hook}"),
        Path.join(dest, ".codex/hooks/#{hook}")
      )
    end

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)
    File.cp!(Path.join(project_root, ".codex/hooks.json"), Path.join(dest, ".codex/hooks.json"))

    File.mkdir_p!(Path.join(dest, "priv/kogen/prompts"))

    for prompt <- ["developer.md", "reviewer.md", "execution-policy.md"] do
      File.cp!(
        Path.join(project_root, "priv/kogen/prompts/#{prompt}"),
        Path.join(dest, "priv/kogen/prompts/#{prompt}")
      )
    end

    File.write!(
      Path.join(dest, "Makefile"),
      ".PHONY: check\n\ncheck:\n\t@test ! -f lib/kogen_fake_break.ex || { echo 'bounded fixture check: lib/kogen_fake_break.ex remains' >&2; exit 1; }\n"
    )

    File.write!(Path.join(dest, "proof.txt"), "route hold fixture selector\n")
    File.mkdir_p!(Path.join(dest, "priv/kogen"))
    File.mkdir_p!(Path.join(dest, "lib"))

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

    File.write!(
      Path.join(dest, ".kogen/config.yaml") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      @route_config_before
    )

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@route_slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @route_intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @route_scenarios_yaml)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)

    hook_dir =
      Path.join(System.tmp_dir!(), "kogen-route-hold-hook-#{System.unique_integer([:positive])}")

    File.mkdir_p!(hook_dir)
    on_exit(fn -> File.rm_rf(hook_dir) end)
    hook_path = Path.join(hook_dir, "midbuild-config-mutation.sh")

    # The fake Developer runs this after each of its turns. The edits persist
    # for the rest of the Build: the first changes the selected route's models
    # and default_route, the second removes the selected route entirely, so a
    # Build that re-read config would launch mutated models or fail.
    # `.kogen/config.yaml` is in this fixture's guarded paths so the edited
    # Candidate is admissible.
    edited = Path.join(hook_dir, "edited.yaml")
    removed = Path.join(hook_dir, "removed.yaml")
    stage = Path.join(hook_dir, "stage")
    File.write!(edited, @route_config_edited)
    File.write!(removed, @route_config_after)

    File.write!(hook_path, """
    #!/bin/sh
    if [ -f #{stage} ]; then
      cp #{removed} .kogen/config.yaml
      echo removed >> #{stage}
    else
      cp #{edited} .kogen/config.yaml
      echo edited > #{stage}
    fi
    """)

    File.chmod!(hook_path, 0o755)

    fake_harness = Path.join(project_root, "test/support/fake_codex")
    prior_harness = System.get_env("KOGEN_HARNESS")
    prior_hook = System.get_env("KOGEN_MIDBUILD_HOOK")
    System.put_env("KOGEN_HARNESS", fake_harness)
    System.put_env("KOGEN_MIDBUILD_HOOK", hook_path)

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")

      if prior_hook,
        do: System.put_env("KOGEN_MIDBUILD_HOOK", prior_hook),
        else: System.delete_env("KOGEN_MIDBUILD_HOOK")
    end)

    result =
      File.cd!(dest, fn ->
        Kogen.Build.run(@route_slug, "other")
      end)

    assert result == :ok, "expected the Build to accept: #{inspect(result)}"

    # Both mid-Build edits happened and stayed in place for later launches.
    assert File.read!(stage) == "edited\nremoved\n"
    assert File.read!(Path.join(dest, ".kogen/config.yaml")) == @route_config_after

    log_lines =
      Path.join(dest, ".kogen/runtime/fake-harness-log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "argv:"))

    developer_or_reviewer_lines =
      Enum.filter(log_lines, &(String.contains?(&1, "exec") and not String.contains?(&1, "auth")))

    assert developer_or_reviewer_lines != []

    for line <- developer_or_reviewer_lines do
      assert line =~ "gpt-other-",
             "every launch must use the frozen route's models, got: #{line}"

      refute line =~ "gpt-mutated-",
             "no launch may use the mid-Build mutated models, got: #{line}"
    end

    developer_prompt =
      Path.join(dest, ".kogen/runtime/developer-launch-prompt") |> File.read!()

    assert developer_prompt =~ "gpt-other-worker",
           "the execution policy in the Developer prompt must name the frozen route's helper profiles"

    reviewer_prompt = Path.join(dest, ".kogen/runtime/reviewer-prompt-1") |> File.read!()

    assert reviewer_prompt =~ "gpt-other-worker",
           "the execution policy in the Reviewer prompt must name the frozen route's helper profiles"

    [record_path] =
      Path.wildcard(Path.join(dest, ".kogen/runtime/scenario-tracking/*/record.json"))

    record = record_path |> File.read!() |> Jason.decode!()

    assert record["route"] == %{
             "name" => "other",
             "harness" => "codex",
             "shaping" => %{"model" => "gpt-other-shape", "effort" => "medium"},
             "developer" => %{"model" => "gpt-other-dev", "effort" => "medium"},
             "reviewer" => %{"model" => "gpt-other-review", "effort" => "high"},
             "helpers" => %{
               "scout" => %{"model" => "gpt-other-scout", "effort" => "low"},
               "worker" => %{"model" => "gpt-other-worker", "effort" => "medium"},
               "expert" => %{"model" => "gpt-other-expert", "effort" => "high"}
             }
           }

    complete_dir = Path.join(dest, ".kogen/intents/complete/#{@route_slug}")
    summary = complete_dir |> Path.join("build-summary.json") |> File.read!() |> Jason.decode!()
    assert summary["schema_version"] == 1
    assert summary["route"] == %{"name" => "other", "harness" => "codex"}

    evidence = complete_dir |> Path.join("evidence.md") |> File.read!()
    assert evidence =~ "Route: `other` (harness `codex`)"
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
