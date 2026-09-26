# Disposable Shaping probe (build-reliability): does managed Codex honour a
# per-launch verdict schema on `exec` and on `exec resume`? Kogen's own scope,
# environment and reviewer flags; only --output-schema content is the probe's.
out = System.get_env("OUT"); mini = System.get_env("MINI")
{:ok, cfg} = Kogen.Intent.read_config(Path.expand(".kogen/config.yaml"), "codex")
{:ok, sel} = Kogen.Codex.open(cfg, mini)
ctx = Kogen.Codex.launch_context(sel)
r = cfg.reviewer
schema = Path.join(out, "schema.json")

run = fn label, args ->
  msg = Path.join(out, "#{label}.message.json")
  File.rm(msg)
  argv = ctx.args ++ args
  File.write!(Path.join(out, "#{label}.argv.json"), Jason.encode!(argv, pretty: true))
  cmd = Enum.map_join([ctx.executable | argv], " ", fn a -> "'" <> String.replace(a, "'", "'\\''") <> "'" end) <> " < " <> Path.join(out, "#{label}.prompt")
  t0 = System.monotonic_time(:millisecond)
  {o, code} = System.cmd("sh", ["-c", cmd], cd: mini, env: Enum.map(ctx.env, & &1) ++ [{"KOGEN_ROLE", "reviewer"}], stderr_to_stdout: true)
  File.write!(Path.join(out, "#{label}.stream.jsonl"), o)
  events = o |> String.split("\n", trim: true) |> Enum.flat_map(fn l -> case Jason.decode(l) do {:ok, e} when is_map(e) -> [e]; _ -> [] end end)
  thread = Enum.find_value(events, fn e -> e["thread_id"] end)
  errors = events |> Enum.filter(&(&1["type"] in ["error", "turn.failed"] or get_in(&1, ["item", "type"]) == "error")) |> Enum.map(&Jason.encode!/1)
  message = case File.read(msg) do {:ok, t} -> t; _ -> nil end
  summary = %{label: label, exit: code, ms: System.monotonic_time(:millisecond) - t0, thread_id: thread,
    message: message && (case Jason.decode(message) do {:ok, m} -> m; _ -> message end), errors: errors,
    nonjson_tail: o |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "{")) |> Enum.take(-15)}
  File.write!(Path.join(out, "#{label}.summary.json"), Jason.encode!(summary, pretty: true))
  IO.puts(Jason.encode!(summary, pretty: true))
  summary
end

a = run.("launch", Kogen.Harness.Codex.reviewer_args(r.model, r.effort) ++ ["--output-schema", schema, "--output-last-message", Path.join(out, "launch.message.json"), "-"])
if a.thread_id do
  flags = Kogen.Harness.Codex.reviewer_args(r.model, r.effort) |> tl()
  run.("reask", ["exec", "resume"] ++ flags ++ ["--output-schema", schema, "--output-last-message", Path.join(out, "reask.message.json"), a.thread_id, "-"])
end
Kogen.Codex.close(sel)
