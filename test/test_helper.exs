# Test modules that need VM-global cwd/environment state are reloaded in a
# private child VM by Kogen.IsolatedCase.  Loading this support module before
# the tests makes the replacement available to every test source.
python_bin =
  if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
    # The parent resolved mise before launching this fresh VM. Repeating
    # `mise which` for every selected test pays a process launch and config
    # lookup without changing that per-invocation toolchain decision.
    bin = System.fetch_env!("KOGEN_TEST_PYTHON_BIN")

    unless File.regular?(Path.join(bin, "python3")),
      do: raise("isolated Python is unavailable: #{bin}")

    bin
  else
    {python, python_status} = System.cmd("mise", ["which", "python3"], stderr_to_stdout: true)

    if python_status != 0 do
      raise "project Python is unavailable through mise: #{String.trim(python)}"
    end

    python
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.find(fn path -> Path.type(path) == :absolute and File.regular?(path) end)
    |> case do
      nil -> raise "mise did not return an installed Python executable: #{python}"
      path -> Path.dirname(path)
    end
  end

System.put_env("PATH", python_bin <> ":" <> System.fetch_env!("PATH"))
System.put_env("KOGEN_TEST_PYTHON_BIN", python_bin)

# The check proof records only this Mix invocation's ExUnit results. Fixture
# Builds inherit the environment and may run nested suites; an explicitly new
# event-log path starts a new owner, while an inherited path keeps its owner.
case System.get_env("KOGEN_TEST_EVENT_LOG") do
  path when is_binary(path) and path != "" ->
    if System.get_env("KOGEN_TEST_EVENT_OWNER_PATH") != path do
      System.put_env("KOGEN_TEST_EVENT_OWNER_PATH", path)
      System.put_env("KOGEN_TEST_EVENT_OWNER_PID", System.pid())
    end

  _ ->
    :ok
end

# Each suite's parent owns a fresh shared-outcome directory for its isolated
# children (see test/support/shared_outcome.ex); a nested suite never reuses
# an outer suite's outcomes.
unless System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
  shared_outcomes =
    Path.join(
      System.tmp_dir!(),
      "kogen-shared-outcomes-#{System.pid()}-#{System.unique_integer([:positive])}"
    )

  File.mkdir_p!(shared_outcomes)
  System.put_env("KOGEN_SHARED_OUTCOME_DIR", shared_outcomes)
  System.at_exit(fn _status -> File.rm_rf(shared_outcomes) end)
end

compile_isolated_modules = fn cache ->
  root = Path.expand("..", __DIR__)

  sources =
    Path.wildcard(Path.join(root, "test/**/*.exs"))
    |> Enum.filter(fn source ->
      supported_tree? = String.contains?(source, "/test/kogen/")

      case {supported_tree?, File.read(source)} do
        {false, _} -> false
        {true, {:ok, contents}} -> String.contains?(contents, "use Kogen.IsolatedCase")
        _ -> false
      end
    end)
    |> Enum.sort()

  compiler =
    """
    Code.require_file(System.fetch_env!("KOGEN_TEST_HELPER"))
    ExUnit.configure(autorun: false)
    cache = System.fetch_env!("KOGEN_ISOLATED_BEAM_CACHE")

    {modules_by_source, unavailable_sources} =
      Enum.reduce(System.argv(), {%{}, %{}}, fn source, {modules, unavailable} ->
        File.write!(Path.join(cache, "progress"), source)
        try do
          compiled = Code.compile_file(source)

          test_modules =
            Enum.filter(compiled, fn {module, _beam} ->
              function_exported?(module, :__ex_unit__, 1)
            end)

          Enum.each(compiled, fn {module, beam} ->
            File.write!(Path.join(cache, Atom.to_string(module) <> ".beam"), beam)
          end)

          case test_modules do
            [{module, _beam} | _] ->
              {Map.put(modules, Path.expand(source), Atom.to_string(module)), unavailable}

            [] ->
              {modules, unavailable}
          end
        rescue
          exception ->
            {modules, Map.put(unavailable, Path.expand(source), Exception.message(exception))}
        catch
          kind, reason ->
            {modules, Map.put(unavailable, Path.expand(source), "\#{kind}: \#{inspect(reason)}")}
        end
      end)

    # A cached test module does not execute its source-level require_file calls
    # in the isolated child. Retain the support modules those calls loaded in
    # this compiler VM, including transitive support dependencies.
    support_root = Path.join(System.fetch_env!("KOGEN_TEST_ROOT"), "test/support") <> "/"

    Code.required_files()
    |> Enum.filter(&String.starts_with?(&1, support_root))
    |> Enum.each(fn source ->
      source
      |> Code.compile_file()
      |> Enum.each(fn {module, beam} ->
        File.write!(Path.join(cache, Atom.to_string(module) <> ".beam"), beam)
      end)
    end)

    manifest = %{modules_by_source: modules_by_source, unavailable_sources: unavailable_sources}
    File.write!(Path.join(cache, "modules.json"), Jason.encode!(manifest))
    """

  code_paths =
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&(Path.type(&1) == :absolute))
    |> Enum.uniq()
    |> Enum.flat_map(fn path -> ["-pa", path] end)

  args = code_paths ++ ["-pa", cache, "-e", compiler, "--" | sources]

  {output, status} =
    System.cmd(
      System.find_executable("elixir") || raise("elixir executable was not found"),
      args,
      stderr_to_stdout: true,
      env: [
        {"KOGEN_ISOLATED_CASE_CHILD", "1"},
        {"KOGEN_ISOLATED_COMPILER", "1"},
        {"KOGEN_ISOLATED_BEAM_CACHE", cache},
        {"KOGEN_TEST_HELPER", Path.join(root, "test/test_helper.exs")}
      ]
    )

  if status != 0 do
    raise "isolated test module cache compile failed (#{status}): #{output}"
  end
end

if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
  Code.ensure_loaded!(Kogen.IsolatedCase)
else
  # Compile support once per invocation, never cache test results. Children only
  # read this private BEAM directory instead of recompiling the helper each time.
  fixture_support = Path.join(__DIR__, "support/verification_fixture.ex")

  support =
    Code.require_file("support/isolated_case.ex", __DIR__) ++
      if(File.regular?(fixture_support), do: Code.require_file(fixture_support), else: []) ++
      Code.require_file("support/candidate_fixture.ex", __DIR__) ++
      Code.require_file("support/workspace_fixture.ex", __DIR__)

  Code.require_file("support/timing_formatter.ex", __DIR__)

  external_cache = System.get_env("KOGEN_ISOLATED_BEAM_CACHE")

  cache =
    external_cache ||
      Path.join(
        System.tmp_dir!(),
        "kogen-test-code-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

  File.mkdir_p!(cache)
  # From this point the bootstrap owns a writable private directory. Register
  # its cleanup before any compiler or cache-preparation step can fail.
  if is_nil(external_cache), do: System.at_exit(fn _ -> File.rm_rf(cache) end)

  # The gate builds this concurrently with its other preparation, into a fresh
  # private directory. Focused tests prepare their own copy here instead.
  guard = System.get_env("KOGEN_TEST_PROCESS_GUARD") || Path.join(cache, "process_group.dylib")

  unless System.get_env("KOGEN_TEST_PROCESS_GUARD") do
    {compiler_output, compiler_status} =
      System.cmd(
        "xcrun",
        [
          "clang",
          "-dynamiclib",
          "-Wall",
          "-Werror",
          Path.join(__DIR__, "support/process_group.c"),
          "-o",
          guard
        ],
        stderr_to_stdout: true
      )

    if compiler_status != 0, do: raise("process containment compile failed: #{compiler_output}")
  end

  unless File.regular?(guard), do: raise("process containment library is missing: #{guard}")

  # Every isolated child is exec'd with this library inserted. A guard the
  # caller supplied (the offline gate's shared cache) is copied once, now that
  # it is known present, into a file this VM owns, so no later change to the
  # shared path can fail a child's exec; children still load the same bytes.
  guard =
    if System.get_env("KOGEN_TEST_PROCESS_GUARD") do
      private =
        Path.join(
          System.tmp_dir!(),
          "kogen-test-guard-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(private)
      System.at_exit(fn _ -> File.rm_rf(private) end)
      copy = Path.join(private, "process_group.dylib")
      File.cp!(guard, copy)
      copy
    else
      guard
    end

  System.put_env("KOGEN_TEST_PROCESS_GUARD", guard)

  Enum.each(support, fn {module, beam} ->
    path = Path.join(cache, Atom.to_string(module) <> ".beam")

    if is_nil(external_cache) or System.get_env("KOGEN_ISOLATED_BEAM_PREPARE") == "1" do
      File.write!(path, beam)
    else
      unless File.regular?(path), do: raise("isolated support cache is missing #{path}")
    end
  end)

  System.put_env("KOGEN_ISOLATED_BEAM_CACHE", cache)

  if System.get_env("KOGEN_ISOLATED_BEAM_PREPARE") == "1" do
    compile_isolated_modules.(cache)
  end

  manifest = Path.join(cache, "modules.json")
  if File.regular?(manifest), do: System.put_env("KOGEN_ISOLATED_BEAM_MANIFEST", manifest)

  # Every fixture Build creates its Candidate worktrees and harness homes in a
  # disposable per-run workspaces root whose path contains a space, never
  # under the real Kogen directory. Child VMs and fixture Builds inherit it; a
  # test that needs its own sets it explicitly.
  workspaces =
    Path.join(
      System.tmp_dir!(),
      "kogen workspaces #{System.pid()}-#{System.unique_integer([:positive])}"
    )

  File.mkdir_p!(workspaces)
  System.at_exit(fn _ -> File.rm_rf(workspaces) end)
  System.put_env("KOGEN_WORKSPACES_ROOT", workspaces)

  # A non-live run never reads the machine's managed Codex or Claude Code
  # install: an admission that forgets to set its own root fails closed on a
  # root that does not exist. Live runs (`--only live`, `--include live`) use
  # the real runtimes. Child VMs inherit this; a test that needs a runtime
  # sets its own root explicitly.
  live_run? =
    Enum.any?(System.argv(), &(&1 in ["live", "--only=live", "--include=live"]))

  unless live_run? do
    missing_runtime_root = Path.join(workspaces, "no-managed-runtime")
    System.put_env("KOGEN_CODEX_ROOT", Path.join(missing_runtime_root, "codex"))
    System.put_env("KOGEN_CLAUDE_ROOT", Path.join(missing_runtime_root, "claude"))
  end
end

# Capture this once while the test VM is still at the checkout root.  Child
# VMs use it as their explicit working directory instead of inheriting a test's
# mutable cwd.
System.put_env("KOGEN_TEST_ROOT", Path.expand("..", __DIR__))

# The offline suite must resolve the harness through its PATH denial shim. A
# test that needs a fake harness sets it inside its own isolated child.
System.delete_env("KOGEN_HARNESS")

# Nested offline suites must not write their fixture records into the parent
# Build's raw evidence directory. Tests that capture logs set their own path.
System.delete_env("KOGEN_RAW_LOG_DIR")

# Fixture commits exercise Git publication without depending on a developer's
# signing key or an interactive signing agent. This override is confined to
# the test process and its disposable repositories.
config_count = System.get_env("GIT_CONFIG_COUNT", "0") |> String.to_integer()
System.put_env("GIT_CONFIG_KEY_#{config_count}", "commit.gpgsign")
System.put_env("GIT_CONFIG_VALUE_#{config_count}", "false")
System.put_env("GIT_CONFIG_COUNT", Integer.to_string(config_count + 1))

# Each isolated case starts a fresh child VM that mostly waits on
# subprocesses. Case concurrency follows the same capacity-based limit as the
# child VM pool (one and a half times the schedulers unless KOGEN_ISOLATED_POOL says
# otherwise), so neither number caps the other.
isolated_case_pool = Kogen.IsolatedCase.Pool.limit()

formatters =
  if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1",
    do: [ExUnit.CLIFormatter],
    else: [ExUnit.CLIFormatter, Kogen.TimingFormatter]

# Tests that must observe an applied write boundary run only where the kernel
# can apply one: inside another Seatbelt profile (a role's shell) the kernel
# refuses a second profile, which its own self-test reports (exit 71). No
# environment variable decides this.
confined? =
  File.regular?("/usr/bin/sandbox-exec") and
    match?(
      {_, 71},
      System.cmd("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)", "/usr/bin/true"],
        stderr_to_stdout: true
      )
    )

ExUnit.start(
  # Mix and isolated children each invoke ExUnit.run/0 explicitly. An at-exit
  # autorun prints a second empty suite and repeats formatter bookkeeping.
  autorun: false,
  exclude: if(confined?, do: [:live, :unconfined], else: [:live]),
  formatters: formatters,
  max_cases: isolated_case_pool
)
