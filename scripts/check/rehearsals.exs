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

Enum.each(rehearsals, fn {target_record, rehearsal, command} ->
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

  IO.puts("+ rehearsal #{target}: #{command}")

  trace_path =
    Path.join(
      System.tmp_dir!(),
      "kogen-rehearsal-#{System.unique_integer([:positive, :monotonic])}.trace"
    )

  {output, status} =
    System.cmd(hd(argv), tl(argv),
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}, {"KOGEN_REHEARSAL_TRACE", trace_path}]
    )

  IO.write(output)

  if status != 0 do
    File.rm(trace_path)
    System.halt(status)
  end

  observed =
    case File.read(trace_path) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> MapSet.new()
      _ -> MapSet.new()
    end

  File.rm(trace_path)

  evidence = %{
    "schema_version" => 1,
    "target" => target,
    "rehearsal_id" => rehearsal["id"],
    "command" => command,
    "status" => status,
    "observed" => MapSet.to_list(observed),
    "trace_sha256" =>
      Base.encode16(:crypto.hash(:sha256, Enum.join(Enum.sort(observed), "\n")), case: :lower)
  }

  unless Kogen.Build.Contract.rehearsal_evidence(target_record, rehearsal, evidence) == :ok do
    raise "rehearsal production evidence was rejected for #{target}"
  end
end)
