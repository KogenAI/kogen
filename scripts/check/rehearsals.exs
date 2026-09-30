Code.require_file("test/support/fixture_validation.ex")
Code.require_file("test/support/prepare_rehearsal.ex")
catalog = YamlElixir.read_from_file!("priv/kogen/verification_targets.yaml")
makefile = File.read!("Makefile")
source_files = Path.wildcard("{lib,test}/**/*.{ex,exs}") ++ Path.wildcard("test/support/**/*")

source =
  Enum.map_join(source_files, "\n", fn path ->
    if File.regular?(path), do: File.read!(path), else: ""
  end)

rehearsals =
  catalog["targets"]
  |> Enum.filter(& &1["provider_backed"])
  |> Enum.map(fn target ->
    rehearsal = Map.fetch!(target, "rehearsal")
    {target, rehearsal, Map.fetch!(rehearsal, "command")}
  end)

ids = Enum.map(rehearsals, fn {target, _, _} -> target["name"] end)

if ids != Enum.uniq(ids) or rehearsals == [] do
  raise "provider-denied rehearsal coverage is missing or duplicated"
end

## Prepare rehearsal (scenario prepare-rehearsed-in-check): every declared
## `prepare` runs the owner's own setup, with providers denied, against a
## controlled passing scope (exit 0, every traced owner entry point
## observed) and a controlled failing scope (nonzero exit, exactly one
## `KOGEN_PREPARE_RESULT` environment frame).
prepares = Enum.filter(catalog["targets"], &Map.has_key?(&1, "prepare"))
prepare_names = Enum.map(prepares, & &1["name"])

if prepare_names != Enum.uniq(prepare_names) do
  raise "prepare rehearsal coverage is duplicated"
end

# The same provider-denied contract `Kogen.Build.Verification.run_prepares/5`
# gives a real `prepare`: PATH resolves `claude`/`codex` to refusing shims,
# provider credentials are removed, and `KOGEN_PROVIDERS_DENIED=1` tells a
# cooperating command so.
prepare_shim_dir =
  Path.join(
    System.tmp_dir!(),
    "kogen-prepare-rehearsal-shims-#{System.unique_integer([:positive, :monotonic])}"
  )

File.mkdir_p!(prepare_shim_dir)

for name <- ~w(claude codex) do
  path = Path.join(prepare_shim_dir, name)

  File.write!(
    path,
    "#!/bin/sh\necho \"rehearsals.exs denied a provider launch during prepare: #{name} $*\" >&2\nexit 97\n"
  )

  File.chmod!(path, 0o755)
end

prepare_credentials =
  ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN
     OPENAI_API_KEY OPENAI_BASE_URL AZURE_OPENAI_API_KEY CODEX_API_KEY)

# test/support/shaping_evaluation/driver.py's `--prepare` mode needs a
# private runtime directory (`KOGEN_SHAPING_EVALUATION_RUNTIME`); every other
# declared prepare command ignores the extra variable.
prepare_runtime_dir =
  Path.join(
    System.tmp_dir!(),
    "kogen-prepare-rehearsal-runtime-#{System.unique_integer([:positive, :monotonic])}"
  )

File.mkdir_p!(prepare_runtime_dir)

# A live target's prepare runs on the Build's selected route, exported into
# this gate as `KOGEN_ROUTE` (the config's default_route only without one);
# the owner entry points it must trace follow that route.
selected_config = Kogen.PrepareRehearsal.selected_config!(File.cwd!())

prepare_denied_env =
  [
    {"KOGEN_ROUTE", selected_config.route},
    {"PATH", prepare_shim_dir <> ":" <> (System.get_env("PATH") || "")},
    {"KOGEN_PROVIDERS_DENIED", "1"},
    {"MIX_ENV", "test"}
  ] ++ Enum.map(prepare_credentials, &{&1, nil})

prepare_results =
  prepares
  |> Task.async_stream(
    fn target_record ->
      target = target_record["name"]
      argv = target_record["prepare"]

      unless is_list(argv) and argv != [] and Enum.all?(argv, &(is_binary(&1) and &1 != "")) do
        raise "declared prepare is not a nonempty argv for #{target}"
      end

      [cmd | args] = argv
      target_runtime = Path.join(prepare_runtime_dir, target)
      File.mkdir_p!(target_runtime)
      target_env = [{"KOGEN_SHAPING_EVALUATION_RUNTIME", target_runtime} | prepare_denied_env]

      trace_entries = get_in(target_record, ["rehearsal", "prepare_trace_assertions"])

      unless is_list(trace_entries) and trace_entries != [] and
               Enum.all?(trace_entries, &is_binary/1) do
        raise "prepare has no traced owner entry points for #{target}"
      end

      trace_entries = Kogen.PrepareRehearsal.required_trace(trace_entries, selected_config)

      IO.puts("+ prepare #{target} (controlled passing scope): #{Enum.join(argv, " ")}")

      pass_trace_path =
        Path.join(
          System.tmp_dir!(),
          "kogen-prepare-rehearsal-#{System.unique_integer([:positive, :monotonic])}.trace"
        )

      # Each generated fixture is validated inside the prepare with providers
      # denied (Kogen.FixtureValidation), recorded here for the aggregate receipt.
      fixture_receipt = pass_trace_path <> ".fixtures"

      pass_started = System.monotonic_time(:millisecond)

      {pass_output, pass_status} =
        System.cmd(cmd, args,
          stderr_to_stdout: true,
          env:
            target_env ++
              [
                {"KOGEN_REHEARSAL_TRACE", pass_trace_path},
                {"KOGEN_FIXTURE_VALIDATION_RECEIPT", fixture_receipt},
                {"KOGEN_PREPARE_FORCE_SCOPE", "pass"},
                {"KOGEN_PREPARE_FORCE_TOOLCHAIN", "pass"}
              ]
        )

      pass_duration_ms = System.monotonic_time(:millisecond) - pass_started

      IO.write(pass_output)

      pass_observed =
        case File.read(pass_trace_path) do
          {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> MapSet.new()
          _ -> MapSet.new()
        end

      File.rm(pass_trace_path)
      fixture_validations = Kogen.FixtureValidation.read_records(fixture_receipt)
      File.rm(fixture_receipt)

      unless pass_status == 0 do
        raise "prepare rehearsal (controlled passing scope) failed for #{target}"
      end

      unless MapSet.subset?(MapSet.new(trace_entries), pass_observed) do
        raise "prepare did not trace its owner's own setup entry points for #{target} " <>
                "(missing: #{inspect(MapSet.difference(MapSet.new(trace_entries), pass_observed))})"
      end

      IO.puts("+ prepare #{target} (controlled failing scope): #{Enum.join(argv, " ")}")

      fail_started = System.monotonic_time(:millisecond)

      {fail_output, fail_status} =
        System.cmd(cmd, args,
          stderr_to_stdout: true,
          env:
            target_env ++
              [
                {"KOGEN_PREPARE_FORCE_SCOPE", "fail"},
                {"KOGEN_PREPARE_FORCE_TOOLCHAIN", "pass"}
              ]
        )

      fail_duration_ms = System.monotonic_time(:millisecond) - fail_started

      IO.write(fail_output)

      if fail_status == 0 do
        raise "prepare rehearsal (controlled failing scope) unexpectedly passed for #{target}"
      end

      frames =
        fail_output
        |> String.split(["\r\n", "\n"])
        |> Enum.filter(&String.starts_with?(&1, "KOGEN_PREPARE_RESULT\t"))

      unless length(frames) == 1 do
        raise "prepare rehearsal (controlled failing scope) did not report exactly one " <>
                "environment frame for #{target}"
      end

      decoded =
        frames
        |> hd()
        |> String.replace_prefix("KOGEN_PREPARE_RESULT\t", "")
        |> Jason.decode!()

      unless decoded["class"] == "environment" and is_binary(decoded["reason"]) and
               decoded["reason"] != "" do
        raise "prepare rehearsal (controlled failing scope) environment frame is malformed for #{target}"
      end

      %{
        "target" => target,
        "pass_status" => pass_status,
        "pass_duration_ms" => pass_duration_ms,
        "pass_observed" => MapSet.to_list(pass_observed),
        "fixture_validations" => fixture_validations,
        "required_trace_assertions" => trace_entries,
        "fail_status" => fail_status,
        "fail_duration_ms" => fail_duration_ms,
        "failure_frame" => decoded
      }
    end,
    # Every prepare is an independent subprocess wait (its own runtime and
    # trace files), so run them all at once instead of three at a time.
    max_concurrency: max(1, min(System.schedulers_online(), length(prepares))),
    timeout: 180_000
  )
  |> Enum.map(fn
    {:ok, result} -> result
    {:exit, reason} -> raise "controlled prepare rehearsal task failed: #{inspect(reason)}"
  end)

File.rm_rf(prepare_shim_dir)
File.rm_rf(prepare_runtime_dir)
# The gate runs this stage beside the main test suite, whose rehearsal trace
# (KOGEN_REHEARSAL_TRACE) is only complete once that suite has finished. The
# prepares above are independent of the trace, so they run first, concurrently
# with the suite; the trace-dependent evidence below waits for the suite's
# completion marker. A failed suite already fails the gate, so nothing more is
# proven here in that case.
if ready_path = System.get_env("KOGEN_REHEARSAL_TRACE_READY") do
  wait_for_suite = fn wait_for_suite ->
    case File.read(ready_path) do
      {:ok, "passed" <> _} ->
        :passed

      {:ok, _} ->
        :failed

      _ ->
        Process.sleep(100)
        wait_for_suite.(wait_for_suite)
    end
  end

  if wait_for_suite.(wait_for_suite) == :failed do
    IO.puts("rehearsal evidence skipped: the main test suite failed")
    System.halt(0)
  end
end

main_trace_path = System.get_env("KOGEN_REHEARSAL_TRACE")
main_trace_bytes = if main_trace_path, do: File.read!(main_trace_path), else: nil

main_observed =
  if main_trace_bytes, do: main_trace_bytes |> String.split("\n", trim: true) |> MapSet.new()

# Bind a rehearsal command to the suite tests it selects: every `test/...`
# file it names must exist and have recorded, all-passed events in the main
# suite's event log. Anything else (no event log, no file argument, a missing
# file, absent or failed tests) is not proven by the suite and must be run.
suite_events =
  with path when is_binary(path) <- System.get_env("KOGEN_REHEARSAL_SUITE_EVENTS"),
       {:ok, bytes} <- File.read(path) do
    Kogen.Build.RehearsalBinding.statuses_by_file(bytes)
  else
    _ -> %{}
  end

command_bound_to_suite? = &Kogen.Build.RehearsalBinding.bound?(&1, suite_events)

validated_rehearsals =
  Enum.map(rehearsals, fn {target_record, rehearsal, command} ->
    target = target_record["name"]
    owners = List.wrap(target_record["owner"])
    fixtures = [rehearsal["correct_fixture"], rehearsal["wrong_fixture"]]

    unless Enum.all?(owners, fn owner ->
             File.regular?(owner) and String.contains?(makefile, owner)
           end) do
      raise "catalog owner coverage is missing or orphaned for #{target}"
    end

    unless Enum.all?(fixtures, fn fixture ->
             fixture |> String.split(":", parts: 2) |> hd() |> File.exists?()
           end) and Enum.uniq(fixtures) == fixtures do
      raise "paired rehearsal fixtures are missing or contradictory for #{target}"
    end

    entrypoints_valid =
      Enum.all?(rehearsal["shared_entrypoints"], fn entrypoint ->
        symbol = entrypoint |> String.split(".") |> List.last()
        String.contains?(source, symbol)
      end)

    unless entrypoints_valid do
      raise "shared production entrypoint coverage drifted for #{target}"
    end

    unless is_list(rehearsal["trace_assertions"]) and rehearsal["trace_assertions"] != [] and
             Enum.all?(rehearsal["trace_assertions"], &is_binary/1) do
      raise "runtime trace assertions are missing for #{target}"
    end

    argv = OptionParser.split(command)

    unless Enum.take(argv, 2) == ["mix", "test"] and "--exclude" in argv and "live" in argv and
             Enum.all?(argv, &(not String.contains?(&1, [";", "|", "&", "`", "$", ">", "<"]))) do
      raise "unsafe rehearsal command for #{target}"
    end

    unless Enum.any?(owners, &String.contains?(command, &1)) or
             Enum.any?(String.split(command), &String.starts_with?(&1, "test/kogen/")) do
      raise "rehearsal command selects no maintained owner or consumer for #{target}"
    end

    {target_record, rehearsal, command, argv}
  end)

# Standalone (no main-suite trace) each rehearsal is its own `mix test`
# boot. They are independent, so run them concurrently and keep the declared
# order in the receipt. With the main-suite trace this is instant.
rehearsal_runs =
  validated_rehearsals
  |> Task.async_stream(
    fn {target_record, rehearsal, command, argv} ->
      target = target_record["name"]
      IO.puts("+ rehearsal #{target}: #{command}")

      bound? = main_observed && command_bound_to_suite?.(argv)
      trace_source = if bound?, do: "main-test-suite", else: "standalone"

      {observed, status, duration_ms, output} =
        if bound? do
          {main_observed, 0, 0, ""}
        else
          trace_path =
            Path.join(
              System.tmp_dir!(),
              "kogen-rehearsal-#{System.unique_integer([:positive, :monotonic])}.trace"
            )

          started = System.monotonic_time(:millisecond)

          {output, status} =
            System.cmd(hd(argv), tl(argv),
              stderr_to_stdout: true,
              env: [{"MIX_ENV", "test"}, {"KOGEN_REHEARSAL_TRACE", trace_path}]
            )

          observed =
            case File.read(trace_path) do
              {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> MapSet.new()
              _ -> MapSet.new()
            end

          File.rm(trace_path)
          {observed, status, System.monotonic_time(:millisecond) - started, output}
        end

      {target_record, rehearsal, command, observed, status, duration_ms, output, trace_source}
    end,
    max_concurrency: max(1, min(System.schedulers_online(), 2)),
    ordered: true,
    timeout: :infinity
  )
  |> Enum.map(fn
    {:ok, result} -> result
    {:exit, reason} -> raise "rehearsal task failed: #{inspect(reason)}"
  end)

rehearsal_results =
  Enum.map(rehearsal_runs, fn {target_record, rehearsal, command, observed, status, duration_ms,
                               output, trace_source} ->
    target = target_record["name"]
    IO.write(output)

    if status != 0, do: System.halt(status)

    evidence = %{
      "schema_version" => 1,
      "target" => target,
      "rehearsal_id" => rehearsal["id"],
      "command" => command,
      "status" => status,
      "duration_ms" => duration_ms,
      "observed" => MapSet.to_list(observed),
      "required_trace_assertions" => rehearsal["trace_assertions"],
      "trace_sha256" =>
        Base.encode16(:crypto.hash(:sha256, Enum.join(Enum.sort(observed), "\n")), case: :lower)
    }

    unless Kogen.Build.Contract.rehearsal_evidence(target_record, rehearsal, evidence) == :ok do
      raise "rehearsal production evidence was rejected for #{target}"
    end

    evidence
    |> Map.put("trace_source", trace_source)
  end)

if receipt_path = System.get_env("KOGEN_REHEARSAL_RECEIPT") do
  File.write!(
    receipt_path,
    Jason.encode!(%{
      "schema_version" => 1,
      "rehearsals" => rehearsal_results,
      "controlled_prepares" => prepare_results,
      "required_rehearsals" => Enum.map(rehearsals, fn {_, rehearsal, _} -> rehearsal["id"] end),
      "required_prepares" => prepare_names
    }) <> "\n"
  )
end
