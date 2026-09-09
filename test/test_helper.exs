# Test modules that need VM-global cwd/environment state are reloaded in a
# private child VM by Kogen.IsolatedCase.  Loading this support module before
# the tests makes the replacement available to every test source.
if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
  Code.ensure_loaded!(Kogen.IsolatedCase)
else
  # Compile support once per invocation, never cache test results. Children only
  # read this private BEAM directory instead of recompiling the helper each time.
  support = Code.require_file("support/isolated_case.ex", __DIR__)
  Code.require_file("support/timing_formatter.ex", __DIR__)

  cache =
    Path.join(
      System.tmp_dir!(),
      "kogen-test-code-#{System.pid()}-#{System.unique_integer([:positive])}"
    )

  File.mkdir!(cache)
  # From this point the bootstrap owns a writable private directory. Register
  # its cleanup before any compiler or cache-preparation step can fail.
  System.at_exit(fn _ -> File.rm_rf(cache) end)

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
  System.put_env("KOGEN_TEST_PROCESS_GUARD", guard)

  Enum.each(support, fn {module, beam} ->
    File.write!(Path.join(cache, Atom.to_string(module) <> ".beam"), beam)
  end)

  Code.prepend_path(cache)
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

# Each isolated case also starts a child VM. One case per parent scheduler
# avoids doubling process startup pressure while independent fixtures overlap.
formatters =
  if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1",
    do: [ExUnit.CLIFormatter],
    else: [ExUnit.CLIFormatter, Kogen.TimingFormatter]

ExUnit.start(
  exclude: [:live],
  formatters: formatters,
  max_cases: System.schedulers_online()
)
