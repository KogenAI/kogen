Code.require_file("../support/route_config.ex", __DIR__)

defmodule Kogen.ClaudeCode.ManagementTest do
  @moduledoc """
  Managed Claude Code scopes, login delegation, isolation and readiness, with
  an offline stand-in installed through the production installer. Personal
  Claude Code state is simulated by an inherited, marker-filled
  CLAUDE_CONFIG_DIR; the real managed root and personal `~/.claude` are never
  touched.
  """
  use Kogen.IsolatedCase, async: true

  import ExUnit.CaptureIO

  alias Kogen.ClaudeCode
  alias Kogen.ClaudeCode.CLI
  alias Kogen.RouteConfig

  @personal_markers %{
    "CLAUDE.md" => "PERSONAL-MEMORY-MARKER",
    "settings.json" => ~s({"model":"PERSONAL-MODEL-MARKER"}),
    "agents/personal.md" => "PERSONAL-AGENT-MARKER",
    ".credentials.json" => "PERSONAL-CREDENTIAL-MARKER"
  }

  setup do
    source = File.cwd!()
    base = Path.join(System.tmp_dir!(), "claude-managed-#{System.unique_integer([:positive])}")
    root = Path.join(base, "Kogen/claude")
    personal_config = Path.join(base, "personal-claude-config")

    for {name, bytes} <- @personal_markers do
      dir = personal_config
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    File.mkdir_p!(root)
    System.put_env("KOGEN_CLAUDE_ROOT", root)
    System.put_env("KOGEN_TEST_NATIVE_TRACE", Path.join(base, "trace.jsonl"))
    System.put_env("CLAUDE_CONFIG_DIR", personal_config)
    System.put_env("ANTHROPIC_API_KEY", "INHERITED-API-KEY")
    System.put_env("ANTHROPIC_BASE_URL", "https://example.invalid")
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "INHERITED-OAUTH-TOKEN")
    System.put_env("CLAUDE_CODE_USE_BEDROCK", "1")
    System.put_env("CLAUDECODE", "1")
    System.put_env("CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT", "0")
    System.delete_env("KOGEN_HARNESS")
    System.delete_env("KOGEN_ROLE")
    {:ok, config} = Kogen.Intent.read_config()
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, root: root, base: base, source: source, config: config, personal: [personal_config]}
  end

  defp install_fixture!(ctx, version \\ []) do
    fixture = Path.join(ctx.source, "test/support/managed_claude_fixture.py")
    installer = Path.join(ctx.source, "priv/kogen/claude_code/install.py")

    assert {_out, 0} =
             System.cmd("python3", [fixture, ctx.root, installer | version],
               stderr_to_stdout: true
             )
  end

  defp trace(ctx) do
    path = Path.join(ctx.base, "trace.jsonl")

    if File.exists?(path),
      do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1),
      else: []
  end

  defp shared(ctx), do: Path.join([ctx.root, "accounts", "shared"])

  defp personal_unchanged!(ctx) do
    for dir <- ctx.personal, {name, bytes} <- @personal_markers do
      assert File.read!(Path.join(dir, name)) == bytes
    end

    refute Enum.any?(trace(ctx), &(&1["scope"] in ctx.personal))
  end

  test "readiness stops before any model launch with the exact fix", ctx do
    assert {:error, reason} = ClaudeCode.open(ctx.config)
    assert reason == "Kogen Claude Code 2.1.281 is not installed. Run mix kogen.claude.install"
    assert trace(ctx) == []

    install_fixture!(ctx)
    assert {:error, reason} = ClaudeCode.open(ctx.config)
    assert reason =~ "Selected shared Kogen Claude Code login is not configured"
    assert reason =~ "Run mix kogen.claude.login"
    assert trace(ctx) == []

    File.mkdir_p!(shared(ctx))
    assert {:error, _logged_out} = ClaudeCode.open(ctx.config)
    assert Enum.map(trace(ctx), & &1["args"]) == [["auth", "status"]]

    File.write!(Path.join(shared(ctx), ".fake-login"), "claude.ai\n")
    assert {:ok, selection} = ClaudeCode.open(ctx.config)
    assert selection.scope.path == Path.expand(shared(ctx))
    assert Enum.all?(trace(ctx), &(&1["args"] == ["auth", "status"]))
    personal_unchanged!(ctx)
  end

  test "shared login opens interactive managed claude in the Kogen scope and forwards arguments",
       ctx do
    install_fixture!(ctx)
    File.mkdir_p!(shared(ctx))
    existing = Path.join(shared(ctx), ".claude.json")
    File.write!(existing, ~s({"existing":"scope state"}))

    assert {:ok, 0} = ClaudeCode.login(["--", "--console"])
    [call] = trace(ctx)
    assert call["args"] == ["--dangerously-skip-permissions", "--console"]
    assert call["scope"] == Path.expand(shared(ctx))
    assert call["executable"] =~ Path.join(ctx.root, "runtimes/2.1.281-")
    assert File.read!(existing) == ~s({"existing":"scope state"})

    for name <-
          ~w(ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDECODE) do
      assert call["env"][name] == nil, "#{name} must be removed from Kogen launches"
    end

    assert call["env"]["DISABLE_AUTOUPDATER"] == "1"
    assert call["env"]["CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT"] == "1"

    assert {:ok, %{login: {:configured, %{auth_method: "console"}}}} =
             ClaudeCode.status()

    personal_unchanged!(ctx)
  end

  test "project login is explicit, never changes shared login, and cancellation never falls back",
       ctx do
    install_fixture!(ctx)
    File.mkdir_p!(shared(ctx))
    File.write!(Path.join(shared(ctx), ".fake-login"), "claude.ai\n")

    assert {:ok, 130} = ClaudeCode.login(["--project", "--", "--cancel"])
    assert {:ok, %{name: :project, path: project_path}} = ClaudeCode.effective_scope()
    assert project_path =~ Path.join(ctx.root, "accounts/projects/")
    assert File.stat!(project_path).mode |> Bitwise.band(0o777) == 0o700

    assert {:error, reason} = ClaudeCode.open(ctx.config)
    assert reason =~ "Run mix kogen.claude.login --project"

    assert {:ok, 0} = ClaudeCode.login(["--project"])
    assert {:ok, %{scope: %{name: :project}}} = ClaudeCode.open(ctx.config)
    assert File.read!(Path.join(shared(ctx), ".fake-login")) == "claude.ai\n"

    assert {:ok, 0} = ClaudeCode.login(["--use-default"])
    assert {:ok, %{name: :shared}} = ClaudeCode.effective_scope()
    assert File.read!(Path.join(project_path, ".fake-login")) == "claude.ai\n"

    assert {:error, _usage} = ClaudeCode.login(["--bogus"])
    personal_unchanged!(ctx)
  end

  test "role launches use the Kogen scope, isolation flags and no personal state", ctx do
    install_fixture!(ctx)
    File.mkdir_p!(shared(ctx))
    File.write!(Path.join(shared(ctx), ".fake-login"), "claude.ai\n")
    config = Map.put(ctx.config, :harness, "claude")

    assert {:ok, selection} = Kogen.Harness.open(config)
    context = Kogen.Harness.launch_context(selection)

    assert {:ok, verdict} =
             Kogen.Harness.launch_reviewer("review", "claude-opus-5-5", "medium", context)

    assert verdict.verdict == "accept"
    call = trace(ctx) |> List.last()
    assert call["scope"] == Path.expand(shared(ctx))
    assert call["env"]["KOGEN_ROLE"] == "reviewer"
    assert call["env"]["HOME"] == System.get_env("HOME")
    assert call["env"]["ANTHROPIC_API_KEY"] == nil
    assert call["env"]["CLAUDE_CODE_OAUTH_TOKEN"] == nil
    assert call["env"]["CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT"] == "1"

    assert ["--setting-sources", "project"] ==
             Enum.take(Enum.drop_while(call["args"], &(&1 != "--setting-sources")), 2)

    assert "--strict-mcp-config" in call["args"]
    refute Enum.any?(call["args"], &(&1 =~ "PERSONAL"))
    personal_unchanged!(ctx)
  end

  test "a retained 2.1.280 default is never launched and survives the 2.1.281 install with logins",
       ctx do
    install_fixture!(ctx, ["2.1.280"])
    File.mkdir_p!(shared(ctx))
    File.write!(Path.join(shared(ctx), ".fake-login"), "claude.ai\n")
    [old] = Path.wildcard(Path.join(ctx.root, "runtimes/2.1.280-*/claude"))
    old_bytes = File.read!(old)

    assert {:error, reason} = ClaudeCode.open(ctx.config)
    assert reason == "Kogen Claude Code 2.1.281 is not installed. Run mix kogen.claude.install"
    assert trace(ctx) == []

    install_fixture!(ctx)
    assert Jason.decode!(File.read!(Path.join(ctx.root, "default.json")))["version"] == "2.1.281"
    assert File.read!(old) == old_bytes
    assert File.read!(Path.join(shared(ctx), ".fake-login")) == "claude.ai\n"

    assert {:ok, selection} = ClaudeCode.open(ctx.config)
    assert selection.runtime["executable"] =~ Path.join(ctx.root, "runtimes/2.1.281-")
    assert selection.scope.path == Path.expand(shared(ctx))
    assert Enum.all?(trace(ctx), &(&1["executable"] =~ "runtimes/2.1.281-"))
    personal_unchanged!(ctx)
  end

  test "status reports pin, installation, scope and login metadata only", ctx do
    output = capture_io(fn -> CLI.run(:status, []) end)
    assert output =~ "Pinned Claude Code: 2.1.281"
    assert output =~ "Not installed. Run mix kogen.claude.install"

    install_fixture!(ctx)
    File.mkdir_p!(shared(ctx))
    File.write!(Path.join(shared(ctx), ".fake-login"), "claude.ai\n")
    output = capture_io(fn -> CLI.run(:status, []) end)
    assert output =~ "Installed: 2.1.281"
    assert output =~ "Effective login: shared (#{Path.expand(shared(ctx))})"
    assert output =~ "loggedIn: true, authMethod: claude.ai"
    refute output =~ "SYNTHETIC-SECRET"
    refute output =~ "SYNTHETIC-ORG"
  end

  test "claude setup commands ignore routes: status and project login work under a codex-only routes config",
       ctx do
    install_fixture!(ctx)
    File.mkdir_p!(shared(ctx))
    File.write!(Path.join(shared(ctx), ".fake-login"), "claude.ai\n")

    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-claude-route-independent-#{System.unique_integer([:positive])}"
      )

    RouteConfig.write!(
      Path.join(dir, ".kogen/config.yaml"),
      [{"codex", RouteConfig.codex_route()}],
      default_route: "codex"
    )

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, %{login: {:configured, _}}} = File.cd!(dir, fn -> ClaudeCode.status() end)

    {result, real_project} =
      File.cd!(dir, fn -> {ClaudeCode.login(["--project", "--", "--cancel"]), File.cwd!()} end)

    assert {:ok, 130} = result
    assert {:ok, %{name: :project}} = ClaudeCode.effective_scope(real_project)
  end

  test "managed roles cannot run setup", _ctx do
    for role <- ~w(developer reviewer shaper expert) do
      System.put_env("KOGEN_ROLE", role)
      assert_raise RuntimeError, ~r/explicit user operation/, fn -> ClaudeCode.install() end

      assert_raise RuntimeError, ~r/explicit user operation/, fn ->
        ClaudeCode.login([])
      end
    end

    System.delete_env("KOGEN_ROLE")
  end

  test "launch environment removes inherited credentials and sets the scope" do
    env =
      ClaudeCode.environment(%{path: "/scope"}, %{
        "ANTHROPIC_API_KEY" => "k",
        "ANTHROPIC_AUTH_TOKEN" => "t",
        "CLAUDE_CODE_USE_VERTEX" => "1",
        "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT" => "0",
        "CLAUDE_CONFIG_DIR" => "/personal",
        "PATH" => "/bin"
      })
      |> Map.new()

    assert env["CLAUDE_CONFIG_DIR"] == "/scope"
    assert env["DISABLE_AUTOUPDATER"] == "1"
    assert env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1"
    assert env["CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT"] == "1"
    assert env["ANTHROPIC_API_KEY"] == nil and Map.has_key?(env, "ANTHROPIC_API_KEY")
    assert env["ANTHROPIC_AUTH_TOKEN"] == nil and Map.has_key?(env, "ANTHROPIC_AUTH_TOKEN")
    assert env["CLAUDE_CODE_USE_VERTEX"] == nil and Map.has_key?(env, "CLAUDE_CODE_USE_VERTEX")
    refute Map.has_key?(env, "PATH")
  end
end
