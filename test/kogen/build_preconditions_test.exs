Code.require_file("../support/precondition_fixture.ex", __DIR__)
Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.BuildPreconditionsTest do
  @moduledoc """
  Scenario `build-refuses-unready-state`: execution precondition
  failures returns `{:error, one_line_reason}` naming the specific failed
  precondition and never invokes the harness. Runs in an isolated OS process (via
  `File.cd!/2`) against real temporary git repos, since `Kogen.Build`,
  `Kogen.Git`, and `Kogen.Check` all resolve relative paths against the
  process's current working directory. Each async case has private
  cwd and environment state.
  """
  @slug "precondition-fixture-intent"

  @valid_intent """
  id: 01960000-0000-7000-8000-0000000000aa
  slug: #{@slug}
  title: Precondition fixture intent
  may_change_guarded_paths:
    - lib/**
  """

  @intent_missing_title """
  id: 01960000-0000-7000-8000-0000000000aa
  slug: #{@slug}
  may_change_guarded_paths:
    - lib/**
  """

  @scenarios_yaml """
  - id: fixture-scenario
    given: a fixture Candidate
    when: the fixture Developer stops
    then: nothing, this fixture never launches a Developer
    wrong_result: the harness gets invoked
    verified_by: [check]
    evidence: fixture only
    proof:
      offline: [test/kogen/focused_fixture_test.exs]
      paid_target: none
      paid_reason: "offline-sufficient: precondition fixture never dispatches"
      affected_paths: [lib/**]
  """

  @config_yaml """
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
  outer_resumptions: 2
  verification_retries: 2
  """

  @claude_config """
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

  @claude_config_unproven String.replace(
                            @claude_config,
                            "developer: {model: claude-opus-5-5",
                            "developer: {model: claude-haiku-4-5-20251001"
                          )

  # A hybrid (role-level) route: Shaping and Developer run on Claude Code (the
  # dominant harness), Reviewer and Expert run on Codex (the adversarial
  # harness). Used to prove readiness for every role's harness is checked,
  # named and refused before any role launch, with no fallback.
  @hybrid_config """
  default_route: hybrid
  routes:
    hybrid:
      shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
      developer: {harness: claude, model: claude-opus-5-5, effort: medium}
      reviewer:  {harness: codex, model: gpt-5.6-terra, effort: high}
      expert:    {harness: codex, model: gpt-5.6-sol, effort: high}
      helpers:
        claude:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
        codex:
          scout:  {model: gpt-5.6-luna, effort: low}
          worker: {model: gpt-5.6-luna, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  # A second route on the same config, distinguishable from the default
  # route's models, used by the --route selection and mid-session mutation
  # tests below.
  @two_route_config """
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
      shaping:   {model: gpt-route-b-shape, effort: medium}
      developer: {model: gpt-route-b-dev, effort: medium}
      reviewer:  {model: gpt-route-b-review, effort: high}
      helpers:
        scout:  {model: gpt-route-b-scout, effort: low}
        worker: {model: gpt-route-b-worker, effort: medium}
        expert: {model: gpt-route-b-expert, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  @makefile """
  .PHONY: check

  check:
  \t@true
  """

  @gitignore """
  .kogen/build.lock
  .kogen/runtime/
  """

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  @project_root Path.expand("../..", __DIR__)
  template =
    if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
      Kogen.PreconditionFixture.child_template!()
    else
      Kogen.PreconditionFixture.create!(
        @project_root,
        [
          {"Makefile", @makefile},
          {".gitignore", @gitignore},
          {".kogen/config.yaml", @config_yaml},
          {"test/kogen/focused_fixture_test.exs", "# focused fixture\n"},
          {"priv/kogen/verification_targets.yaml",
           Jason.encode!(%{
             "targets" => [
               %{
                 "name" => "check",
                 "cost_class" => "offline",
                 "rank" => 0,
                 "dependencies" => [],
                 "provider_backed" => false,
                 "owner" => "fixture"
               }
             ]
           })},
          {".kogen/intents/approved/#{@slug}/intent.yaml", @valid_intent},
          {".kogen/intents/approved/#{@slug}/scenarios.yaml", @scenarios_yaml}
        ],
        @git_env
      )
    end

  @template template

  unless System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
    ExUnit.after_suite(fn _ -> File.rm_rf(template) end)
  end

  @precondition_cases [
                        %{
                          case: "intent.yaml missing title",
                          operation: :missing_title,
                          expected: "missing required key: title"
                        },
                        %{
                          case: "dirty worktree",
                          operation: :dirty_worktree,
                          expected: "worktree is not clean"
                        },
                        %{
                          case: "detached HEAD",
                          operation: :detached_head,
                          expected: "detached HEAD"
                        },
                        %{
                          case: "existing Complete package",
                          operation: :complete_package,
                          expected: "Complete Intent already exists"
                        },
                        %{
                          case:
                            "many individually valid Approved files exceed the aggregate budget",
                          operation: :approved_aggregate_oversize,
                          expected: "largest contributors: \"evidence-a.bin\"=4000000"
                        },
                        %{
                          case: "missing configuration",
                          operation: :missing_config,
                          expected: "missing .kogen/config.yaml"
                        },
                        %{
                          case: "missing required helper profile",
                          operation:
                            {:config_replacement,
                             "  expert: {model: gpt-5.6-sol, effort: medium}\n", ""},
                          expected: "helpers.expert"
                        },
                        %{
                          case: "blank configured root model",
                          operation:
                            {:config_replacement, "developer: {model: gpt-5.6-sol, effort: low}",
                             "developer: {model: \"\", effort: low}"},
                          expected: "developer.model"
                        },
                        %{
                          case: "wrong-typed configured helper effort",
                          operation:
                            {:config_replacement, "worker: {model: gpt-5.6-luna, effort: medium}",
                             "worker: {model: gpt-5.6-luna, effort: 42}"},
                          expected: "helpers.worker.effort"
                        },
                        %{
                          case: "missing check target",
                          operation: :missing_check_target,
                          expected: "Makefile has no check target"
                        },
                        %{
                          case: "missing verification policy",
                          operation: :missing_policy,
                          expected: "required verification policy file"
                        },
                        %{
                          case: "missing verification hook registration",
                          operation: :missing_hook_registration,
                          expected: "verification-policy hook is not registered"
                        },
                        %{
                          case: "undeclared verification target",
                          operation: {:verification_target, "not-declared"},
                          expected: "undeclared make target"
                        },
                        %{
                          case: "unsafe verification target",
                          operation: {:verification_target, "--eval=bad"},
                          expected: "refused unsafe target name"
                        },
                        %{
                          case: "assume-unchanged tracked Makefile is refused before launch",
                          operation: {:index_flag, "--assume-unchanged"},
                          expected: "assume-unchanged"
                        },
                        %{
                          case: "skip-worktree tracked Makefile is refused before launch",
                          operation: {:index_flag, "--skip-worktree"},
                          expected: "skip-worktree"
                        },
                        %{
                          case: "scalar scenarios",
                          operation: {:scenarios, "- scalar\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scalar verified_by",
                          operation: {:scenarios, "- verified_by: check\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "empty scenarios",
                          operation: {:scenarios, "[]\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "empty verified_by",
                          operation: {:scenarios, "- verified_by: []\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "duplicate scenario IDs",
                          operation: {:scenarios, @scenarios_yaml <> @scenarios_yaml},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "blank scenario id",
                          operation: {:scenario_replacement, "id: fixture-scenario", "id: "},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "blank scenario given",
                          operation:
                            {:scenario_replacement, "given: a fixture Candidate", "given: "},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "blank scenario when",
                          operation:
                            {:scenario_replacement, "when: the fixture Developer stops", "when: "},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "blank scenario then",
                          operation:
                            {:scenario_replacement,
                             "then: nothing, this fixture never launches a Developer", "then: "},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "blank scenario wrong result",
                          operation:
                            {:scenario_replacement, "wrong_result: the harness gets invoked",
                             "wrong_result: "},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "blank scenario evidence",
                          operation:
                            {:scenario_replacement, "evidence: fixture only", "evidence: "},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scenario missing given",
                          operation: {:scenario_remove_line, "given: a fixture Candidate"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scenario missing id",
                          operation: {:scenario_remove_line, "id: fixture-scenario"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scenario missing when",
                          operation: {:scenario_remove_line, "when: the fixture Developer stops"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scenario missing then",
                          operation:
                            {:scenario_remove_line,
                             "then: nothing, this fixture never launches a Developer"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scenario missing wrong result",
                          operation:
                            {:scenario_remove_line, "wrong_result: the harness gets invoked"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scenario missing evidence",
                          operation: {:scenario_remove_line, "evidence: fixture only"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scenario missing verification targets",
                          operation: {:scenario_remove_line, "verified_by: [check]"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "risks scalar list element",
                          operation: {:risks, "- scalar\n"},
                          expected: "risks.yaml missing or invalid"
                        },
                        %{
                          case: "risk points at a missing scenario",
                          operation:
                            {:risks,
                             "- id: risk-one\n  scenario_ids: [missing]\n  description: fixture risk\n"},
                          expected: "risks.yaml missing or invalid"
                        },
                        %{
                          case: "duplicate risk IDs",
                          operation:
                            {:risks,
                             "- id: risk-one\n  scenario_ids: [fixture-scenario]\n  description: first\n- id: risk-one\n  scenario_ids: [fixture-scenario]\n  description: second\n"},
                          expected: "risks.yaml missing or invalid"
                        },
                        %{
                          case: "risk ownership omits a required dimension",
                          operation:
                            {:risks,
                             "- id: risk-one\n  scenario_ids: [fixture-scenario]\n  description: fixture risk\n  ownership:\n    - paths: dummy.txt\n      when_exists: always\n      owner_after_creation: Build\n      owner_during_operation: Build\n      permitted_mutation: none\n      validation: check\n      upgrade_behavior: none\n"},
                          expected: "risks.yaml missing or invalid"
                        },
                        %{
                          case: "non-string title",
                          operation:
                            {:intent_replacement, "title: Precondition fixture intent",
                             "title: []"},
                          expected: "title"
                        },
                        %{
                          case: "non-string guarded path",
                          operation: {:intent_replacement, "  - lib/**", "  - 123"},
                          expected: "may_change_guarded_paths"
                        },
                        %{
                          case: "mismatched slug",
                          operation:
                            {:intent_replacement, "slug: #{@slug}", "slug: other-intent"},
                          expected: "slug does not match"
                        },
                        %{
                          case: "unsupported configured harness",
                          operation: :unsupported_harness,
                          expected: "unsupported harness"
                        },
                        %{
                          case: "configured Claude Code runtime is not installed",
                          operation: {:claude, :uninstalled},
                          expected:
                            "Kogen Claude Code 2.1.281 is not installed. Run mix kogen.claude.install"
                        },
                        %{
                          case: "configured Claude Code shared login is missing",
                          operation: {:claude, :logged_out},
                          expected: "Run mix kogen.claude.login"
                        },
                        %{
                          case: "configured Claude Code project login is missing",
                          operation: {:claude, :project_logged_out},
                          expected: "Run mix kogen.claude.login --project"
                        },
                        %{
                          case: "configured Claude Code model is not proven",
                          operation: {:claude, :unproven_model},
                          expected:
                            "unsupported Claude Code model for developer: claude-haiku-4-5-20251001"
                        },
                        %{
                          case:
                            "hybrid route's adversarial Codex harness (Reviewer and Expert) is not installed",
                          operation: {:hybrid, :codex_not_installed},
                          expected:
                            "reviewer and expert harness codex is not ready: Kogen Codex is not installed. Run mix kogen.codex.install"
                        },
                        %{
                          case: "negative resumption budget",
                          operation: :negative_resumption_budget,
                          expected: "outer_resumptions"
                        },
                        %{
                          case: "existing build lock",
                          operation: :existing_lock,
                          expected: "build lock already present"
                        },
                        %{
                          case: "TypeSafe Jev Keychain item is missing",
                          operation: :jev_key_missing,
                          expected:
                            "the macOS Keychain has no generic password for service `ai.typesafe.api`"
                        }
                      ]
                      |> Enum.map(&Map.put(&1, :template, @template))

  use Kogen.IsolatedCase, async: true, parameterize: @precondition_cases

  test "precondition failures never launch the harness", %{
    operation: operation,
    expected: expected
  } do
    run_precondition_case(operation, expected)
  end

  test "a missing Jev Keychain item fails before any launch, tracking record or verification context" do
    dir = tmp_repo!()
    write_intent(dir, @valid_intent)

    harness_dir =
      Path.join(System.tmp_dir!(), "kogen-jev-key-#{System.unique_integer([:positive])}")

    File.mkdir_p!(harness_dir)
    on_exit(fn -> File.rm_rf(harness_dir) end)
    marker = Path.join(harness_dir, "harness-invoked")
    log = Path.join(harness_dir, "security.log")
    System.put_env("KOGEN_HARNESS", write_fake_harness!(harness_dir, marker))
    System.put_env("FAKE_SECURITY_LOG", log)
    System.put_env("FAKE_SECURITY_ITEM", "missing")

    assert {:error, reason} = File.cd!(dir, fn -> Kogen.Build.run(@slug) end)
    assert reason =~ "`ai.typesafe.api`"
    assert reason =~ "security add-generic-password -s ai.typesafe.api -a <account> -w"
    refute File.exists?(marker), "the Developer harness must never launch"
    refute File.exists?(Path.join(dir, ".kogen/runtime/scenario-tracking"))
    assert Path.wildcard(Path.join(dir, ".kogen/runtime/**/context.json")) == []
    refute File.exists?(Path.join(dir, ".kogen/build.lock"))
    # The existence check never asks for the value (-w).
    assert File.read!(log) == "find-generic-password -s ai.typesafe.api\n"

    # With the item present the same precondition passes; every Build fixture
    # in the offline suite runs with the present fake item.
    System.put_env("FAKE_SECURITY_ITEM", "present")
    assert :ok = Kogen.Jev.key_present()
  end

  test "a flat-shaped config.yaml is refused before any launch and no tracking record is created" do
    fixture = route_fixture!("route-flat-refused")
    slug = write_route_build_package!(fixture)

    File.write!(Path.join(fixture, ".kogen/config.yaml"), """
    harness: codex
    shaping:   {model: gpt-5.6-sol, effort: low}
    developer: {model: gpt-5.6-sol, effort: low}
    reviewer:  {model: gpt-5.6-terra, effort: medium}
    helpers:
      scout:  {model: gpt-5.6-luna, effort: low}
      worker: {model: gpt-5.6-luna, effort: medium}
      expert: {model: gpt-5.6-sol, effort: medium}
    outer_resumptions: 2
    verification_retries: 2
    """)

    init_route_git!(fixture)

    {output, 1} =
      Kogen.CompiledFixture.mix_task!(fixture, ["kogen.build", slug], route_env(fixture))

    assert output =~
             "config.yaml uses the replaced flat configuration shape (top-level harness and roles); define default_route and routes instead"

    refute File.exists?(Path.join(fixture, ".kogen/runtime/fake-harness-log")),
           "the flat config must be refused before any fake-harness launch"

    refute Path.wildcard(Path.join(fixture, ".kogen/runtime/scenario-tracking/*")) != [],
           "no tracking record may be created when config resolution fails"
  end

  test "an unknown --route fails before launch, naming the route and listing available routes sorted" do
    fixture = route_fixture!("route-unknown-refused")
    slug = write_route_build_package!(fixture)
    File.write!(Path.join(fixture, ".kogen/config.yaml"), @two_route_config)
    init_route_git!(fixture)

    {output, 1} =
      Kogen.CompiledFixture.mix_task!(
        fixture,
        ["kogen.build", "--route", "missing", slug],
        route_env(fixture)
      )

    assert output =~ "unknown route: missing; available routes: codex, other"

    refute File.exists?(Path.join(fixture, ".kogen/runtime/fake-harness-log")),
           "an unknown route must be refused before any fake-harness launch"

    assert Path.wildcard(Path.join(fixture, ".kogen/runtime/scenario-tracking/*")) == [],
           "no tracking record may be created when route selection fails"
  end

  test "a missing --route value or an unknown option print the command's usage line" do
    fixture = route_fixture!("route-usage")
    slug = write_route_build_package!(fixture)
    File.write!(Path.join(fixture, ".kogen/config.yaml"), @two_route_config)
    init_route_git!(fixture)

    usage = "usage: mix kogen.build [--route <name>] <slug>"

    {missing_value_output, 1} =
      Kogen.CompiledFixture.mix_task!(fixture, ["kogen.build", "--route"], route_env(fixture))

    assert missing_value_output =~ usage

    {unknown_option_output, 1} =
      Kogen.CompiledFixture.mix_task!(
        fixture,
        ["kogen.build", "--unknown-option", slug],
        route_env(fixture)
      )

    assert unknown_option_output =~ usage

    refute File.exists?(Path.join(fixture, ".kogen/runtime/fake-harness-log")),
           "usage failures must be refused before any fake-harness launch"
  end

  test "--route selects a non-default route's Developer, Reviewer, and execution-policy profiles" do
    default_fixture = route_fixture!("route-flag-selects-default")
    default_slug = write_route_build_package!(default_fixture)
    File.write!(Path.join(default_fixture, ".kogen/config.yaml"), @two_route_config)
    init_route_git!(default_fixture)

    {_default_output, 0} =
      Kogen.CompiledFixture.mix_task!(
        default_fixture,
        ["kogen.build", default_slug],
        route_env(default_fixture)
      )

    default_prompt =
      File.read!(Path.join(default_fixture, ".kogen/runtime/developer-launch-prompt"))

    # The default route's developer root and helper profiles are named.
    assert default_prompt =~ "gpt-5.6-sol"
    assert default_prompt =~ "gpt-5.6-luna"
    refute default_prompt =~ "gpt-route-b"

    default_reviewer_prompt =
      File.read!(Path.join(default_fixture, ".kogen/runtime/reviewer-prompt-1"))

    assert default_reviewer_prompt =~ "gpt-5.6-terra"
    refute default_reviewer_prompt =~ "gpt-route-b"

    other_fixture = route_fixture!("route-flag-selects-other")
    other_slug = write_route_build_package!(other_fixture)
    File.write!(Path.join(other_fixture, ".kogen/config.yaml"), @two_route_config)
    init_route_git!(other_fixture)

    {_other_output, 0} =
      Kogen.CompiledFixture.mix_task!(
        other_fixture,
        ["kogen.build", "--route", "other", other_slug],
        route_env(other_fixture)
      )

    other_prompt = File.read!(Path.join(other_fixture, ".kogen/runtime/developer-launch-prompt"))
    assert other_prompt =~ "gpt-route-b-dev"
    assert other_prompt =~ "gpt-route-b-worker"
    refute other_prompt =~ "gpt-5.6-sol"
    refute other_prompt =~ "gpt-5.6-luna"

    other_reviewer_prompt =
      File.read!(Path.join(other_fixture, ".kogen/runtime/reviewer-prompt-1"))

    assert other_reviewer_prompt =~ "gpt-route-b-review"
    refute other_reviewer_prompt =~ "gpt-5.6-terra"
  end

  # -- fixture plumbing --------------------------------------------------

  defp run_precondition_case(operation, expected) do
    dir = tmp_repo!()
    setup_case!(dir, operation)
    approved_before = approved_bytes(dir)
    index_before = real_index_bytes(dir)

    # The fake harness and its marker live entirely outside the git repo
    # under test, so writing/invoking it can never itself dirty the
    # worktree and confound the precondition under test.
    harness_dir =
      Path.join(System.tmp_dir!(), "kogen-precond-harness-#{System.unique_integer([:positive])}")

    File.mkdir_p!(harness_dir)
    on_exit(fn -> File.rm_rf(harness_dir) end)

    marker = Path.join(harness_dir, "harness-invoked")
    fake_harness = write_fake_harness!(harness_dir, marker)

    previous_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)
    trace = claude_readiness!(dir, harness_dir, operation)

    on_exit(fn ->
      if previous_harness do
        System.put_env("KOGEN_HARNESS", previous_harness)
      else
        System.delete_env("KOGEN_HARNESS")
      end
    end)

    lock_was_present = File.exists?(Path.join(dir, ".kogen/build.lock"))

    result =
      File.cd!(dir, fn ->
        Kogen.Build.run(@slug)
      end)

    assert {:error, reason} = result
    assert reason =~ expected
    assert File.exists?(Path.join(dir, ".kogen/build.lock")) == lock_was_present
    refute File.exists?(marker), "the fake harness marker exists: the harness was invoked"
    refute_role_launch!(trace)
    assert approved_bytes(dir) == approved_before
    assert {"", 0} = System.cmd("git", ["diff", "--cached", "--"], cd: dir)
    assert real_index_bytes(dir) == index_before
  end

  defp setup_case!(dir, :missing_title), do: write_intent(dir, @intent_missing_title)

  defp setup_case!(dir, :approved_aggregate_oversize) do
    write_intent(dir, @valid_intent)
    approved = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.write!(Path.join(approved, "evidence-a.bin"), :binary.copy(<<1>>, 4_000_000))
    File.write!(Path.join(approved, "evidence-b.bin"), :binary.copy(<<2>>, 4_000_000))
    File.write!(Path.join(approved, "evidence-c.bin"), :binary.copy(<<3>>, 4_000_000))
  end

  defp setup_case!(dir, :dirty_worktree) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, "dirty.txt"), "uncommitted\n")
  end

  defp setup_case!(dir, :detached_head) do
    write_intent(dir, @valid_intent)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    {_out, 0} = System.cmd("git", ["checkout", "-q", String.trim(sha)], cd: dir)
  end

  defp setup_case!(dir, :complete_package) do
    write_intent(dir, @valid_intent)
    complete = Path.join(dir, ".kogen/intents/complete/#{@slug}")
    File.mkdir_p!(complete)
    File.write!(Path.join(complete, "intent.yaml"), @valid_intent)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_config) do
    write_intent(dir, @valid_intent)
    File.rm!(Path.join(dir, ".kogen/config.yaml"))
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:config_replacement, old, replacement}) do
    write_intent(dir, @valid_intent)

    File.write!(
      Path.join(dir, ".kogen/config.yaml"),
      String.replace(@config_yaml, old, replacement)
    )

    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_check_target) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, "Makefile"), "other:\n\t@true\n")
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_policy) do
    write_intent(dir, @valid_intent)
    File.rm!(Path.join(dir, ".codex/hooks/verification_policy.py"))
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_hook_registration) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, ".codex/hooks.json"), ~s({"hooks":{"Stop":[]}}))
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:verification_target, target}) do
    write_intent(dir, @valid_intent)
    scenarios = String.replace(@scenarios_yaml, "[check]", inspect([target]))
    File.write!(Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"), scenarios)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:index_flag, flag}) do
    write_intent(dir, @valid_intent)
    makefile = Path.join(dir, "Makefile")
    assert {_out, 0} = System.cmd("git", ["update-index", flag, "Makefile"], cd: dir)
    File.write!(makefile, @makefile <> "# hidden behind #{flag}\n")
  end

  defp setup_case!(dir, {:scenarios, scenarios}) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"), scenarios)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:scenario_replacement, old, replacement}) do
    write_intent(dir, @valid_intent)

    File.write!(
      Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"),
      String.replace(@scenarios_yaml, old, replacement)
    )

    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:scenario_remove_line, line}) do
    write_intent(dir, @valid_intent)

    File.write!(
      Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"),
      @scenarios_yaml |> String.replace("  #{line}\n", "") |> String.replace("- #{line}\n", "-\n")
    )

    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:risks, risks}) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, ".kogen/intents/approved/#{@slug}/risks.yaml"), risks)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:intent_replacement, old, replacement}) do
    write_intent(dir, String.replace(@valid_intent, old, replacement))
  end

  defp setup_case!(dir, :unsupported_harness) do
    write_intent(dir, @valid_intent)

    File.write!(
      Path.join(dir, ".kogen/config.yaml"),
      String.replace(@config_yaml, "harness: codex", "harness: unsupported")
    )

    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:claude, state}) do
    write_intent(dir, @valid_intent)
    config = if state == :unproven_model, do: @claude_config_unproven, else: @claude_config
    File.write!(Path.join(dir, ".kogen/config.yaml"), config)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:hybrid, :codex_not_installed}) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, ".kogen/config.yaml"), @hybrid_config)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :negative_resumption_budget) do
    write_intent(dir, @valid_intent)

    File.write!(
      Path.join(dir, ".kogen/config.yaml"),
      String.replace(@config_yaml, "outer_resumptions: 2", "outer_resumptions: -1")
    )

    commit_fixture!(dir)
  end

  defp setup_case!(dir, :existing_lock) do
    write_intent(dir, @valid_intent)
    lock_dir = Path.join(dir, ".kogen")
    File.mkdir_p!(lock_dir)
    File.write!(Path.join(lock_dir, "build.lock"), "")
  end

  defp setup_case!(dir, :jev_key_missing) do
    write_intent(dir, @valid_intent)
    System.put_env("FAKE_SECURITY_ITEM", "missing")
    on_exit(fn -> System.delete_env("FAKE_SECURITY_ITEM") end)
  end

  # Claude Code readiness uses the real managed-runtime route (no fake harness
  # override) with a private managed root and an offline stand-in runtime whose
  # every invocation is traced. Readiness may ask `auth status`; no role may run.
  defp claude_readiness!(dir, harness_dir, {:claude, state}) do
    System.delete_env("KOGEN_HARNESS")
    root = Path.join(harness_dir, "claude")
    trace = Path.join(harness_dir, "claude-trace.jsonl")
    File.mkdir_p!(root)
    System.put_env("KOGEN_CLAUDE_ROOT", root)
    System.put_env("KOGEN_TEST_NATIVE_TRACE", trace)

    if state in [:logged_out, :project_logged_out] do
      assert {_out, 0} =
               System.cmd(
                 "python3",
                 [
                   Path.join(@project_root, "test/support/managed_claude_fixture.py"),
                   root,
                   Path.join(@project_root, "priv/kogen/claude_code/install.py")
                 ],
                 stderr_to_stdout: true
               )

      shared = Path.join(root, "accounts/shared")
      File.mkdir_p!(shared)
    end

    if state == :project_logged_out do
      File.write!(Path.join(root, "accounts/shared/.fake-login"), "claude.ai\n")

      # This fixture step stands in for the user's own explicit login. A role
      # inherited from an enclosing managed Developer shell must not leak into
      # it; the Build under test still runs with the inherited environment.
      role = System.get_env("KOGEN_ROLE")
      System.delete_env("KOGEN_ROLE")

      try do
        assert {:ok, 130} =
                 File.cd!(dir, fn ->
                   Kogen.ClaudeCode.login(["--project", "--", "--cancel"])
                 end)
      after
        if role, do: System.put_env("KOGEN_ROLE", role)
      end
    end

    trace
  end

  # A hybrid route's readiness uses real managed readiness for both harnesses
  # (no `KOGEN_HARNESS` override, which would otherwise bypass both harnesses'
  # own readiness checks): Claude Code is installed and logged in so the
  # dominant harness (Shaping and Developer) opens successfully, while Codex's
  # managed root is a fresh, unmanaged directory so the adversarial harness
  # (Reviewer and Expert) is refused as not installed. Build must stop there,
  # naming both roles and the Codex harness, before any role launches and
  # without falling back to Claude Code for the Reviewer.
  defp claude_readiness!(_dir, harness_dir, {:hybrid, :codex_not_installed}) do
    System.delete_env("KOGEN_HARNESS")
    root = Path.join(harness_dir, "claude")
    trace = Path.join(harness_dir, "claude-trace.jsonl")
    File.mkdir_p!(root)
    System.put_env("KOGEN_CLAUDE_ROOT", root)
    System.put_env("KOGEN_TEST_NATIVE_TRACE", trace)
    System.put_env("KOGEN_CODEX_ROOT", Path.join(harness_dir, "codex-not-installed"))

    assert {_out, 0} =
             System.cmd(
               "python3",
               [
                 Path.join(@project_root, "test/support/managed_claude_fixture.py"),
                 root,
                 Path.join(@project_root, "priv/kogen/claude_code/install.py")
               ],
               stderr_to_stdout: true
             )

    shared = Path.join(root, "accounts/shared")
    File.mkdir_p!(shared)
    File.write!(Path.join(shared, ".fake-login"), "claude.ai\n")

    on_exit(fn ->
      System.delete_env("KOGEN_CLAUDE_ROOT")
      System.delete_env("KOGEN_CODEX_ROOT")
      System.delete_env("KOGEN_TEST_NATIVE_TRACE")
    end)

    trace
  end

  defp claude_readiness!(_dir, _harness_dir, _operation), do: nil

  defp refute_role_launch!(nil), do: :ok

  defp refute_role_launch!(trace) do
    launches =
      if File.exists?(trace),
        do: trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1),
        else: []

    refute Enum.any?(launches, &("-p" in &1["args"])),
           "readiness must stop before any Claude Code role launch: #{inspect(launches)}"
  end

  defp tmp_repo! do
    dir = Kogen.PreconditionFixture.copy!(@template)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_intent(dir, intent_yaml) do
    intent_dir = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    intent_path = Path.join(intent_dir, "intent.yaml")
    scenarios_path = Path.join(intent_dir, "scenarios.yaml")

    changed? =
      File.read!(intent_path) != intent_yaml or File.read!(scenarios_path) != @scenarios_yaml

    if changed? do
      File.write!(intent_path, intent_yaml)
      File.write!(scenarios_path, @scenarios_yaml)

      {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

      {_out, 0} =
        System.cmd("git", ["commit", "-q", "-m", "add intent fixture"], cd: dir, env: @git_env)
    end
  end

  defp commit_fixture!(dir) do
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture setup"], cd: dir, env: @git_env)
  end

  defp write_fake_harness!(dir, marker) do
    path = Path.join(dir, "fake-harness-that-must-never-run")

    File.mkdir_p!(dir)

    File.write!(path, """
    #!/bin/sh
    mkdir -p "$(dirname "#{marker}")"
    echo "invoked: $*" >> "#{marker}"
    exit 1
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp approved_bytes(dir) do
    root = Path.join(dir, ".kogen/intents/approved/#{@slug}")

    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
    |> Enum.sort()
  end

  defp real_index_bytes(dir) do
    {path, 0} = System.cmd("git", ["rev-parse", "--git-path", "index"], cd: dir)
    path |> String.trim() |> Path.expand(dir) |> File.read!()
  end

  # -- route fixture plumbing (public mix kogen.build task, fake codex) --

  @route_slug "route-fixture-intent"

  defp route_fixture!(label) do
    fixture = Kogen.CompiledFixture.create!(@project_root, label)
    on_exit(fn -> File.rm_rf(fixture) end)
    fixture
  end

  defp route_env(fixture) do
    [{"KOGEN_HARNESS", Path.join(fixture, "test/support/fake_codex")}]
  end

  defp write_route_build_package!(fixture) do
    path = Path.join(fixture, ".kogen/intents/approved/#{@route_slug}")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "intent.yaml"), """
    id: 01960000-0000-7000-8000-0000000000rf
    slug: #{@route_slug}
    title: Route fixture intent
    may_change_guarded_paths:
      - dummy.txt
    """)

    File.write!(Path.join(path, "scenarios.yaml"), """
    - id: route-fixture-scenario
      given: a fixture Candidate
      when: the fake Reviewer accepts it
      then: the Build commits normally
      wrong_result: the wrong route's profiles are used
      verified_by: [check]
      evidence: fixture only
    """)

    # The fake Codex reviewer accepts a first-attempt Candidate only when it
    # matches an explicit requirement, so the initial fresh Developer's write
    # to dummy.txt is accepted without a Reviewer-requested rework round.
    File.write!(
      Path.join(path, "requirement.json"),
      Jason.encode!(%{"path" => "dummy.txt", "expected" => "initial fixture value"})
    )

    File.write!(Path.join(fixture, "dummy.txt"), "")

    Kogen.VerificationFixture.install!(fixture)
    @route_slug
  end

  defp init_route_git!(fixture) do
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "route fixture baseline"],
        cd: fixture,
        env: @git_env
      )
  end
end
