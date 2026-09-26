Code.require_file("../support/workspace_fixture.ex", __DIR__)

defmodule Kogen.HarnessHomeTest do
  @moduledoc """
  Scenario `per-build-harness-home`: every Claude Code launch of a fake
  -harness Build (readiness, fresh Developer, its exact resume, Reviewer) has
  the Build's own `CLAUDE_CONFIG_DIR` under the harness home,
  `CLAUDE_SECURESTORAGE_CONFIG_DIR` naming the scope bound once from control
  at admission, the caller's real `HOME`, and none of the variables Kogen
  removes -- observed in the environment the fake role actually saw, from its
  own launch receipt (`Kogen.CandidateFixture.receipts/1`,
  `test/support/launch_receipt.py`), not from launch arguments. Readiness ran
  first. A mid-Build login-selector switch never reaches an already-bound
  launch. The owner and tracking records name the binding. The scope
  directory is untouched by the whole fake Build. A recording fake `security`
  first on `PATH` is never invoked. A marker in one Build's harness home
  never reaches a second Build.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.CandidateFixture
  alias Kogen.WorkspaceFixture

  @moduletag timeout: 120_000

  setup do
    System.delete_env("KOGEN_ROLE")
    :ok
  end

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

  @removed_var_plants [
    {"CLAUDE_SECURESTORAGE_CONFIG_DIR", ""},
    {"CLAUDE_CODE_OAUTH_TOKEN", "INHERITED-OAUTH-TOKEN"},
    {"ANTHROPIC_API_KEY", "INHERITED-ANTHROPIC-KEY"},
    {"CODEX_HOME", "/inherited/codex/home"},
    {"OPENAI_API_KEY", "INHERITED-OPENAI-KEY"},
    {"CLAUDE_CONFIG_DIR", "/inherited/claude/config"}
  ]

  defp claude_root!(base) do
    root = Path.join(base, "claude-root")
    File.mkdir_p!(Path.join(root, "accounts/shared"))
    root
  end

  defp control_with_claude_route! do
    control = WorkspaceFixture.create!()
    File.write!(Path.join(control, ".kogen/config.yaml"), @claude_config)
    WorkspaceFixture.git!(control, ["add", "-A"])
    WorkspaceFixture.git!(control, ["commit", "-q", "-m", "use the claude route"])
    control
  end

  defp security_recorder!(base) do
    dir = Path.join(base, "path-shim")
    File.mkdir_p!(dir)
    log = Path.join(base, "security-invoked.log")

    File.write!(Path.join(dir, "security"), """
    #!/bin/sh
    printf 'invoked: %s\\n' "$*" >> #{inspect(log)}
    exit 1
    """)

    File.chmod!(Path.join(dir, "security"), 0o755)
    {dir, log}
  end

  test "every Claude Code launch of a fake Build is bound, homed, readiness-first, unleaked and record-named" do
    base = WorkspaceFixture.tmp_dir!("harness-home")
    on_exit(fn -> File.rm_rf(base) end)
    control = control_with_claude_route!()
    root = claude_root!(base)
    scope = Path.join(root, "accounts/shared")
    scope_files_before = scope |> Path.join("**/*") |> Path.wildcard() |> Enum.sort()
    {shim_dir, security_log} = security_recorder!(base)

    env =
      @removed_var_plants ++
        [
          {"KOGEN_CLAUDE_ROOT", root},
          {"PATH", shim_dir <> ":" <> System.get_env("PATH", "")}
        ]

    assert :ok =
             WorkspaceFixture.build!(control,
               harness: WorkspaceFixture.support("fake_claude"),
               env: env
             )

    refute File.exists?(security_log),
           "Kogen must never invoke a `security` executable, even one shadowing PATH"

    assert scope |> Path.join("**/*") |> Path.wildcard() |> Enum.sort() == scope_files_before

    record = CandidateFixture.record(control)
    candidate_block = Map.fetch!(record, "candidate")
    harness_home = Map.fetch!(candidate_block, "harness_home")
    home_config_dir = Path.join(harness_home, "claude")

    [claude_binding] =
      Enum.filter(candidate_block["credential_bindings"], &(&1["harness"] == "claude"))

    assert claude_binding["scope_path"] == Path.expand(scope)
    assert claude_binding["scope_name"] == "shared"
    assert claude_binding["runtime_version"] == "test"

    # A published Build's owner record is removed at publication (only the
    # tracking record, always kept in control, survives); its schema and
    # binding fields are the same `Kogen.Build.Workspace.write_owner/4` shape
    # asserted directly in build_workspace_test.exs's admission/publication
    # coverage, so this Build's `credential_bindings` (asserted above from the
    # tracking record's `candidate` block, which mirrors it field for field)
    # is the reachable proof here.
    assert Map.has_key?(candidate_block, "owner_record")

    receipts = CandidateFixture.receipts(control)
    assert receipts != []

    # Readiness (`claude auth status`) is identified by its argv, not its
    # role: it runs with the Build's own launch environment before role
    # dispatch assigns `KOGEN_ROLE`, but that variable may already be set in
    # this process's own environment (the ambient `KOGEN_ROLE` a role's own
    # shell runs Kogen commands under), so the receipt's `argv` is the
    # reliable signal.
    readiness = Enum.filter(receipts, &(&1["argv"] == ["auth", "status"]))
    model_roles = Enum.reject(receipts, &(&1["argv"] == ["auth", "status"]))
    assert readiness != [], "expected at least one readiness (`auth status`) receipt"
    assert model_roles != [], "expected at least one Developer/Reviewer launch receipt"

    # `receipts/1` sorts oldest first (the receipt file name embeds
    # nanosecond time); readiness must be the very first launch of the Build.
    assert List.first(receipts)["argv"] == ["auth", "status"]

    assert Enum.any?(model_roles, &(&1["role"] == "developer"))
    assert Enum.any?(model_roles, &(&1["role"] == "reviewer"))

    for receipt <- receipts do
      env = receipt["env"]

      assert env["CLAUDE_CONFIG_DIR"] == home_config_dir,
             "launch #{inspect(receipt["argv"])} used CLAUDE_CONFIG_DIR #{inspect(env["CLAUDE_CONFIG_DIR"])}"

      assert env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == Path.expand(scope)
      assert env["HOME"] == System.get_env("HOME")

      for {removed, _planted} <- @removed_var_plants,
          removed not in ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR"] do
        refute Map.has_key?(env, removed), "#{removed} leaked into #{receipt["role"]} launch"
      end
    end
  end

  test "a login-selector switch mid-Build never reaches the frozen binding" do
    base = WorkspaceFixture.tmp_dir!("harness-home-selector")
    on_exit(fn -> File.rm_rf(base) end)
    control = control_with_claude_route!()
    root = claude_root!(base)
    File.mkdir_p!(Path.join(root, "accounts/projects"))

    WorkspaceFixture.with_env(
      [{"KOGEN_CLAUDE_ROOT", root}, {"KOGEN_HARNESS", WorkspaceFixture.support("fake_claude")}],
      fn ->
        assert {:ok, binding} = Kogen.ClaudeCode.bind(control)
        assert binding.scope.name == :shared

        # The Build's own launch: `:binding` is the one frozen at admission and
        # is never re-resolved from the current selector.
        launch = %{
          root: control,
          harness_home: Path.join(base, "harness"),
          binding: binding,
          env: [],
          prefix: [],
          tmp_dir: Path.join(base, "tmp")
        }

        config = %{harness: "claude"}

        assert {:ok, before_switch} = Kogen.ClaudeCode.open(config, control, launch)
        assert before_switch.scope.name == :shared

        # Flip the project's selector to `project` mid-"Build" -- exactly like
        # `mix kogen.claude.login --project` would, but without requiring the
        # real managed installer this fake-harness test never installs.
        selector = Path.join([root, "preferences", Kogen.ClaudeCode.project_id(control)])
        File.mkdir_p!(Path.dirname(selector))
        File.write!(selector, "project\n")

        assert {:ok, after_switch} = Kogen.ClaudeCode.open(config, control, launch)
        assert after_switch.scope.name == :shared
        assert after_switch.scope.path == before_switch.scope.path

        # Proof the flip is real and would matter to any launch that re-resolved
        # instead of using the frozen binding.
        assert {:ok, %{name: :project}} = Kogen.ClaudeCode.effective_scope(control)
      end
    )
  end

  test "a marker in one Build's harness home never reaches a second Build" do
    base = WorkspaceFixture.tmp_dir!("harness-home-isolation")
    on_exit(fn -> File.rm_rf(base) end)
    # Two independent controls under the same workspaces root, so each gets
    # its own project directory and harness homes never collide by slug.
    first_control = control_with_claude_route!()
    second_control = control_with_claude_route!()
    root = claude_root!(base)

    env = [{"KOGEN_CLAUDE_ROOT", root}]

    assert :ok =
             WorkspaceFixture.build!(first_control,
               harness: WorkspaceFixture.support("fake_claude"),
               env: env
             )

    first_home = CandidateFixture.harness_home(first_control)
    marker = Path.join(first_home, "planted-marker")
    File.write!(marker, "only the first Build's home\n")

    assert :ok =
             WorkspaceFixture.build!(second_control,
               harness: WorkspaceFixture.support("fake_claude"),
               env: env
             )

    second_home = CandidateFixture.harness_home(second_control)
    refute second_home == first_home
    refute File.exists?(Path.join(second_home, "planted-marker"))

    for receipt <- CandidateFixture.receipts(second_home, home: true) do
      refute receipt["env"]["KOGEN_HARNESS_HOME"] == first_home
      refute Map.has_key?(receipt["env"], "PLANTED_MARKER")
    end
  end
end
