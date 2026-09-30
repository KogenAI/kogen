defmodule Kogen.TimingFormatter do
  @moduledoc false
  use GenServer

  def init(_options) do
    Process.put(:isolation_guard, Kogen.IsolationGuard.new())
    {:ok, {[], :unknown}}
  end

  def handle_cast({:test_started, test}, state) do
    guard_check(fn guard -> Kogen.IsolationGuard.started(guard, test) end)
    {:noreply, state}
  end

  def handle_cast({:test_finished, test}, {timings, mode}) do
    guard_check(fn guard -> Kogen.IsolationGuard.finished(guard, test) end)
    entry = {test.time || 0, test.module, test.name}
    dry_run? = System.get_env("KOGEN_TEST_DRY_RUN") == "1"
    if not dry_run?, do: record_test(test)
    next_mode = if(dry_run? or Map.has_key?(test.tags, :live), do: mode, else: :executed)
    {:noreply, {[entry | timings], next_mode}}
  end

  # `mix test --dry-run` sends `module_finished` with the discovered test list
  # but does not send a `test_finished` for every selected test. Keep this
  # public ExUnit event as the source for immutable-base inventories.
  def handle_cast({:module_finished, %{tests: tests, parameters: parameters}}, {timings, mode}) do
    dry_run? = System.get_env("KOGEN_TEST_DRY_RUN") == "1"

    if dry_run? or mode in [:unknown, :enumerating],
      do: Enum.each(tests, &record_test(&1, "enumerated", parameters))

    {:noreply, {timings, if(dry_run? or mode == :unknown, do: :enumerating, else: mode)}}
  end

  def handle_cast({:suite_finished, _times}, {timings, mode}) do
    guard_check(&Kogen.IsolationGuard.check/1)
    guard_report()
    IO.puts("\nSlowest individual cases (includes isolated process startup):")

    timings
    |> Enum.sort(:desc)
    |> Enum.take(8)
    |> Enum.each(fn {microseconds, module, name} ->
      IO.puts("  #{Float.round(microseconds / 1_000_000, 3)}s #{inspect(module)} #{name}")
    end)

    write_timing_summary(timings)

    {:noreply, {timings, mode}}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc """
  Maps an ExUnit test state to the recorded status. Excluded and skipped tests
  did not run and are not failures; failed and invalid ones are.
  """
  def status(nil), do: "passed"
  def status({:excluded, _}), do: "excluded"
  def status({:skipped, _}), do: "skipped"
  def status({:failed, _}), do: "failed"
  def status({:invalid, _}), do: "failed"
  def status(_other), do: "failed"

  defp guard_check(fun) do
    Process.put(:isolation_guard, fun.(Process.get(:isolation_guard)))
  end

  # ExUnit formatters cannot fail a suite, so a violation is printed loudly and
  # the VM exits non-zero, the same way `mix test` reports failed tests.
  defp guard_report do
    case Kogen.IsolationGuard.violations(Process.get(:isolation_guard)) do
      [] ->
        :ok

      violations ->
        IO.puts(:stderr, "\nISOLATION GUARD VIOLATION: shared-VM cwd/environment changed")
        Enum.each(violations, &IO.puts(:stderr, "  " <> &1))
        System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp write_timing_summary(timings) do
    owner_pid = System.get_env("KOGEN_TEST_EVENT_OWNER_PID")

    # Nested fixture suites inherit the warm gate's path. Only the outer
    # selected suite may write its diagnostic timing inventory.
    path =
      if owner_pid in [nil, "", System.pid()],
        do: System.get_env("KOGEN_TEST_TIMING_SUMMARY"),
        else: nil

    case path do
      path when path in [nil, ""] ->
        :ok

      path ->
        cases =
          timings
          |> Enum.map(fn {microseconds, module, name} ->
            %{
              "duration_us" => microseconds,
              "module" => Atom.to_string(module),
              "name" => to_string(name)
            }
          end)
          |> Enum.sort_by(fn test ->
            {-test["duration_us"], test["module"], test["name"]}
          end)

        modules =
          cases
          |> Enum.group_by(& &1["module"])
          |> Enum.map(fn {module, tests} ->
            durations = Enum.map(tests, & &1["duration_us"])

            %{
              "case_count" => length(tests),
              "max_duration_us" => Enum.max(durations),
              "module" => module,
              "total_duration_us" => Enum.sum(durations)
            }
          end)
          |> Enum.sort_by(fn summary ->
            {-summary["total_duration_us"], summary["module"]}
          end)

        summary = %{
          "case_count" => length(cases),
          "cases" => cases,
          "modules" => modules,
          "schema_version" => 1,
          "total_case_duration_us" => Enum.sum(Enum.map(cases, & &1["duration_us"]))
        }

        File.write(path, Jason.encode!(summary) <> "\n")
    end
  end

  defp record_test(test, forced_status \\ nil, forced_parameters \\ nil) do
    case System.get_env("KOGEN_TEST_EVENT_LOG") do
      path when path in [nil, ""] ->
        :ok

      path ->
        owner_pid = System.get_env("KOGEN_TEST_EVENT_OWNER_PID")
        owner_path = System.get_env("KOGEN_TEST_EVENT_OWNER_PATH")

        owned? = owner_pid == System.pid() and owner_path == path

        immutable_base_dry_run? =
          System.get_env("KOGEN_TEST_DRY_RUN") == "1" and
            owner_pid in [nil, ""] and owner_path in [nil, ""]

        if owned? or immutable_base_dry_run? do
          maybe_record_test(path, test, forced_status, forced_parameters)
        end
    end
  end

  defp maybe_record_test(path, test, forced_status, forced_parameters) do
    tags = Map.get(test, :tags, %{})

    unless Map.has_key?(tags, :live) do
      event = test_event(test, tags, forced_status, forced_parameters)
      File.write!(path, Jason.encode!(event) <> "\n", [:append])
    end
  end

  defp test_event(test, tags, forced_status, forced_parameters) do
    file = Map.get(tags, :file, "") |> to_string() |> String.replace("\\", "/")
    root = System.get_env("KOGEN_TEST_ROOT") || File.cwd!()
    relative_file = Path.relative_to(Path.expand(file, root), root) |> String.replace("\\", "/")
    status = forced_status || status(Map.get(test, :state))

    parameters =
      forced_parameters || Map.get(test, :parameters) || Map.get(tags, :parameters) ||
        Map.get(tags, :parameterized) || %{}

    %{
      "file" => relative_file,
      "module" => test.module |> Atom.to_string(),
      "name" => test.name |> to_string(),
      "parameters" => normalize(parameters),
      "status" => status
    }
  end

  defp normalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), normalize(item)} end)
    |> Enum.sort()
    |> Map.new()
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> normalize()
  defp normalize(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp normalize(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
end

defmodule Kogen.IsolationGuard do
  @moduledoc false
  # Runtime counterpart of the static cwd_isolation_guard_test: the shared test
  # VM's working directory and `KOGEN_*`, `HOME`, `CODEX_HOME`,
  # `CLAUDE_CONFIG_DIR` and `MIX_*` variables must not change while tests run.
  # Snapshots are compared at every test start and finish; a change names the
  # tests in flight at that moment as suspects.

  @exact ~w(HOME CODEX_HOME CLAUDE_CONFIG_DIR)
  @prefixes ["KOGEN_", "MIX_"]

  def snapshot do
    env =
      for {name, value} <- System.get_env(),
          name in @exact or Enum.any?(@prefixes, &String.starts_with?(name, &1)),
          into: %{},
          do: {name, value}

    %{cwd: File.cwd!(), env: env}
  end

  def new, do: %{baseline: snapshot(), inflight: MapSet.new(), violations: []}

  def started(guard, test), do: guard |> check() |> update_inflight(&MapSet.put(&1, id(test)))

  def finished(guard, test),
    do: guard |> check(id(test)) |> update_inflight(&MapSet.delete(&1, id(test)))

  def check(guard, extra \\ nil, current \\ nil) do
    current = current || snapshot()

    case diff(guard.baseline, current) do
      [] ->
        guard

      changes ->
        suspects = guard.inflight |> MapSet.put(extra) |> MapSet.delete(nil) |> Enum.sort()
        message = "#{Enum.join(changes, "; ")} -- tests in flight: #{Enum.join(suspects, ", ")}"
        # Re-baseline so one offender is reported once, not by every later test.
        %{guard | baseline: current, violations: [message | guard.violations]}
    end
  end

  def violations(guard), do: Enum.reverse(guard.violations)

  def diff(before, after_) do
    cwd = if before.cwd != after_.cwd, do: ["cwd #{before.cwd} -> #{after_.cwd}"], else: []

    env =
      (Map.keys(before.env) ++ Map.keys(after_.env))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(&(Map.get(before.env, &1) != Map.get(after_.env, &1)))
      |> Enum.map(fn name ->
        "env #{name} #{inspect(Map.get(before.env, name))} -> #{inspect(Map.get(after_.env, name))}"
      end)

    cwd ++ env
  end

  defp id(test), do: "#{inspect(test.module)} #{test.name}"
  defp update_inflight(guard, fun), do: %{guard | inflight: fun.(guard.inflight)}
end
