Code.require_file("../support/route_config.ex", __DIR__)

defmodule Kogen.Codex.ManagementTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Codex
  alias Kogen.Codex.State
  alias Kogen.RouteConfig

  setup do
    source = File.cwd!()

    root =
      Path.join(
        System.tmp_dir!(),
        "managed-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    System.put_env("KOGEN_CODEX_ROOT", root)
    System.put_env("KOGEN_TEST_NATIVE_TRACE", Path.join(root, "trace.jsonl"))
    System.delete_env("KOGEN_HARNESS")
    System.delete_env("KOGEN_ROLE")
    {:ok, config} = Kogen.Intent.read_config(".kogen/config.yaml", "codex")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, source: source, config: config}
  end

  test "managed roles, including the Expert, cannot run setup", ctx do
    for role <- ~w(developer reviewer shaper expert) do
      System.put_env("KOGEN_ROLE", role)

      assert_raise RuntimeError, ~r/explicit user operation/, fn -> Codex.install() end
      assert_raise RuntimeError, ~r/explicit user operation/, fn -> Codex.login([]) end
    end

    System.delete_env("KOGEN_ROLE")
    refute File.exists?(Path.join(ctx.root, "trace.jsonl"))
  end

  # A test VM prepends a private `kogen-test-code-*` directory, which the
  # code server treats as a `kogen` application directory. Readiness must
  # still find the managed installer and report the real state.
  test "readiness ignores a code-path entry that shadows the kogen application", ctx do
    shadow = Path.join(ctx.root, "kogen-shadow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(shadow)
    Code.prepend_path(shadow)
    on_exit(fn -> Code.delete_path(shadow) end)
    assert to_string(:code.lib_dir(:kogen)) == shadow

    assert {:error, reason} = Codex.open(ctx.config)
    assert reason =~ "mix kogen.codex.install"
    install_fixture!(ctx)
    assert {:error, reason} = Codex.open(ctx.config)
    assert reason =~ "mix kogen.codex.login"
  end

  test "missing runtime and explicit scope preflight never call a provider", ctx do
    assert {:error, reason} = Codex.open(ctx.config)
    assert reason =~ "mix kogen.codex.install"
    refute File.exists?(Path.join(ctx.root, "trace.jsonl"))
    install_fixture!(ctx)
    assert {:error, reason} = Codex.open(ctx.config)
    assert reason =~ "mix kogen.codex.login"
    refute File.exists?(Path.join(ctx.root, "trace.jsonl"))

    authenticate_shared!(ctx)
    State.select_scope!(ctx.root, ctx.source, :project)
    assert {:error, reason} = Codex.open(ctx.config)
    assert reason =~ "mix kogen.codex.login --project"
    assert trace(ctx.root) == []
  end

  test "saved native UI bookkeeping permits status and readiness without rewriting account state",
       ctx do
    install_fixture!(ctx)
    authenticate_shared!(ctx)
    {:ok, scope} = Codex.effective_scope()
    path = Path.join(scope.path, "config.toml")
    bytes = "[tui.model_availability_nux]\n\"gpt-5.6-sol\" = 1\n"
    File.write!(path, bytes)
    assert {:ok, %{login: :configured}} = Codex.status()
    assert {:ok, selection} = Codex.open(ctx.config)
    Codex.close(selection)
    assert File.read!(path) == bytes
    assert File.read!(Path.join(scope.path, "auth.json")) == "shared-account"
  end

  test "readiness status does not consume the actual launch context receipt", ctx do
    install_fixture!(ctx)
    authenticate_shared!(ctx)
    receipt = Path.join(ctx.root, "managed-launch-context.json")
    System.put_env("KOGEN_CODEX_CONTEXT_RECEIPT", receipt)

    assert {:ok, selection} = Codex.open(ctx.config)
    refute File.exists?(receipt)
    context = Codex.launch_context(selection)
    assert File.regular?(receipt)
    assert Jason.decode!(File.read!(receipt))["executable"] == context.executable
    Codex.close(selection)
  end

  test "scope selector persists independently of credentials and use-default retains them", ctx do
    install_fixture!(ctx)
    authenticate_shared!(ctx)
    State.select_scope!(ctx.root, ctx.source, :project)
    {:ok, project_scope} = Codex.effective_scope()
    State.ensure_scope!(project_scope.path)
    File.write!(Path.join(project_scope.path, "auth.json"), "project-account")
    assert {:ok, selection} = Codex.open(ctx.config)
    assert selection.scope == project_scope
    Codex.close(selection)
    File.rm!(Path.join(project_scope.path, "auth.json"))
    assert {:error, reason} = Codex.open(ctx.config)
    assert reason =~ "--project"
    File.write!(Path.join(project_scope.path, "auth.json"), "retained-project-account")
    assert {:ok, 0} = Codex.login(["--use-default"])
    assert {:ok, %{name: :shared}} = Codex.effective_scope()
    assert File.read!(Path.join(project_scope.path, "auth.json")) == "retained-project-account"

    assert File.read!(Path.join([ctx.root, "accounts", "shared", "auth.json"])) ==
             "shared-account"

    assert {:ok, %{name: :shared}} = Codex.effective_scope(ctx.source <> "-another-project")
  end

  test "status and launch distinguish validator prerequisites from foreign settings", ctx do
    install_fixture!(ctx)
    authenticate_shared!(ctx)
    {:ok, scope} = Codex.effective_scope()
    settings = Path.join(scope.path, "config.toml")
    bytes = "[tui.model_availability_nux]\n\"gpt-5.6-sol\" = 1\n"
    File.write!(settings, bytes)
    python = System.find_executable("python3")
    bin = Path.join(ctx.root, "python-control")
    File.mkdir!(bin)
    shim = Path.join(bin, "python3")

    File.write!(shim, """
    #!/bin/sh
    case "$1" in
      */native_settings.py) exit 2 ;;
      *) exec #{shell_quote(python)} "$@" ;;
    esac
    """)

    File.chmod!(shim, 0o755)
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    assert {:ok, %{login: {:error, reason}}} = Codex.status()
    assert reason =~ "Python 3.11"
    refute reason =~ "unexpected discovery"
    assert {:error, reason} = Codex.open(ctx.config)
    assert reason =~ "Python 3.11"
    assert File.read!(settings) == bytes
    assert File.read!(Path.join(scope.path, "auth.json")) == "shared-account"
    refute File.exists?(Path.join(ctx.root, "trace.jsonl"))

    System.put_env("PATH", bin)
    File.rm!(shim)

    assert_raise RuntimeError, ~r/requires Python 3.11/, fn ->
      State.native_projects!(scope.path)
    end
  end

  test "status uses native status only, omits native secret text, and counts actual active leases",
       ctx do
    assert {:ok, %{runtime: nil, active: [], login: :unavailable}} = Codex.status()
    install_fixture!(ctx)
    authenticate_shared!(ctx)
    assert {:ok, selection} = Codex.open(ctx.config)
    assert {:ok, %{active: [active], login: :configured}} = Codex.status()
    assert active["runtime"]["version"] == "0.156.1"
    assert Enum.all?(trace(ctx.root), &(Enum.take(&1["args"], -2) == ["login", "status"]))
    Codex.close(selection)
    assert {:ok, %{active: []}} = Codex.status()
  end

  test "selected work retains its pinned executable despite default pointer and PATH changes",
       ctx do
    install_fixture!(ctx)
    authenticate_shared!(ctx)
    System.put_env("OPENAI_API_KEY", "hostile-personal-override")
    assert {:ok, old} = Codex.open(ctx.config)
    old_context = Codex.launch_context(old)
    assert {:ok, _} = Codex.installer("activate", ["0.200.0", "0.154.0"])
    assert {:ok, fresh} = Codex.open(ctx.config)
    assert old.runtime["executable"] == fresh.runtime["executable"]
    assert fresh.runtime["version"] == "0.156.1"
    personal_bin = Path.join(ctx.root, "personal-bin")
    File.mkdir!(personal_bin)
    File.write!(Path.join(personal_bin, "codex"), "#!/bin/sh\nexit 87\n")
    File.chmod!(Path.join(personal_bin, "codex"), 0o755)
    System.put_env("PATH", personal_bin <> ":" <> System.fetch_env!("PATH"))
    assert Codex.launch_context(old).executable == old_context.executable

    assert {:ok, %{session_id: "managed-developer"}} =
             Kogen.Harness.launch_developer("fixture", "fake", "low", [], old_context)

    assert {:ok, %{session_id: "managed-developer"}} =
             Kogen.Harness.resume_developer(
               "managed-developer",
               "resume",
               "fake",
               "low",
               [],
               Codex.launch_context(old)
             )

    assert {:ok, %{session_id: "managed-reviewer"}} =
             Kogen.Harness.launch_reviewer(
               "independent",
               "fake",
               "low",
               Codex.launch_context(old)
             )

    launched = trace(ctx.root) |> Enum.filter(&("exec" in &1["args"]))
    assert length(launched) == 3
    assert Enum.all?(launched, &(&1["executable"] == old.runtime["executable"]))
    assert Enum.all?(trace(ctx.root), &is_nil(&1["override"]))
    Codex.close(old)
    Codex.close(fresh)
  end

  test "an operation already using the retained 0.154.0 runtime keeps it across the 0.156.1 upgrade",
       ctx do
    install_fixture!(ctx)
    authenticate_shared!(ctx)
    assert {:ok, %{"version" => "0.154.0"} = previous} = Codex.installer("inspect")
    {:ok, scope} = Codex.effective_scope(ctx.source)

    in_flight = %{
      harness: "codex",
      runtime: previous,
      scope: scope,
      config: ctx.config,
      project: ctx.source,
      operation: State.operation!(ctx.root),
      lease: State.lease!(ctx.root, previous, ctx.source)
    }

    assert {:ok, %{"version" => "0.156.1"} = upgraded} = Codex.installer("install")
    assert {:ok, ^upgraded} = Codex.installer("inspect")
    assert upgraded["executable"] != previous["executable"]
    assert {:ok, %{active: [active]}} = Codex.status()
    assert active["runtime"] == previous

    assert {:ok, %{session_id: "managed-developer"}} =
             Kogen.Harness.launch_developer(
               "in flight",
               "fake",
               "low",
               [],
               Codex.launch_context(in_flight)
             )

    assert {:ok, fresh} = Codex.open(ctx.config)
    assert fresh.runtime == upgraded

    assert {:ok, %{session_id: "managed-developer"}} =
             Kogen.Harness.launch_developer(
               "fresh",
               "fake",
               "low",
               [],
               Codex.launch_context(fresh)
             )

    launched = trace(ctx.root) |> Enum.filter(&("exec" in &1["args"]))

    assert Enum.map(launched, & &1["executable"]) == [
             previous["executable"],
             upgraded["executable"]
           ]

    assert File.read!(Path.join(scope.path, "auth.json")) == "shared-account"
    Codex.close(in_flight)
    Codex.close(fresh)
  end

  test "codex setup commands ignore routes: status and project login work under a claude-only routes config",
       ctx do
    install_fixture!(ctx)
    authenticate_shared!(ctx)

    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-codex-route-independent-#{System.unique_integer([:positive])}"
      )

    RouteConfig.write!(
      Path.join(dir, ".kogen/config.yaml"),
      [{"claude", RouteConfig.claude_route()}],
      default_route: "claude"
    )

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, %{login: :configured}} = File.cd!(dir, fn -> Codex.status() end)

    {result, real_project} =
      File.cd!(dir, fn -> {Codex.login(["--project", "--", "--help"]), File.cwd!()} end)

    assert {:ok, 0} = result
    assert {:ok, %{name: :project}} = Codex.effective_scope(real_project)
  end

  test "wrapper parsing forwards native arguments verbatim and rejects conflicting options",
       _ctx do
    assert {:ok, :project, ["--help", "--native-future", "a b"]} =
             Codex.login_arguments(["--project", "--", "--help", "--native-future", "a b"])

    assert {:error, _} = Codex.login_arguments(["--project", "--use-default"])
    assert {:error, _} = Codex.login_arguments(["--with-api-key"])
    assert {:error, _} = Codex.login_arguments(["--use-default", "--", "--help"])
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp install_fixture!(ctx) do
    {output, status} =
      System.cmd(
        "python3",
        [
          Path.join(ctx.source, "test/support/managed_codex_fixture.py"),
          ctx.root,
          Path.join(ctx.source, "priv/kogen/codex/install.py")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp authenticate_shared!(ctx) do
    scope = Path.join([ctx.root, "accounts", "shared"])
    State.ensure_scope!(scope)
    File.write!(Path.join(scope, "auth.json"), "shared-account")
  end

  defp trace(root) do
    case File.read(Path.join(root, "trace.jsonl")) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end
end
