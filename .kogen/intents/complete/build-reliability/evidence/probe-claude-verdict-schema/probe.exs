# Disposable Shaping probe (build-reliability): does Claude Code honour a
# per-launch verdict schema (enum, minItems=maxItems, path pattern, receipt)
# on a fresh -p launch and on --resume? Uses Kogen's own scope and flags.
out = System.get_env("OUT"); mini = System.get_env("MINI")
{:ok, cfg} = Kogen.Intent.read_config(Path.expand(".kogen/config.yaml"), "claude")
route = cfg
{:ok, sel} = Kogen.ClaudeCode.open(route, mini)
ctx = Kogen.ClaudeCode.launch_context(sel)
schema = File.read!(Path.join(out, "schema.json"))
reviewer = route.reviewer

run = fn label, session, prompt ->
  args = Kogen.Harness.Claude.reviewer_args(reviewer.model, reviewer.effort, ctx, "00000000-0000-4000-8000-000000000000")
  i = Enum.find_index(args, &(&1 == "--json-schema"))
  args = List.replace_at(args, i + 1, schema)
  j = Enum.find_index(args, &(&1 == "--session-id"))
  args = Enum.take(args, j) ++ session
  File.write!(Path.join(out, "#{label}.prompt"), prompt)
  cmd = Enum.map_join([ctx.executable | args], " ", fn a -> "'" <> String.replace(a, "'", "'\\''") <> "'" end) <> " < " <> Path.join(out, "#{label}.prompt")
  t0 = System.monotonic_time(:millisecond)
  {o, code} = System.cmd("sh", ["-c", cmd], cd: mini, env: Enum.map(ctx.env, fn {k, v} -> {k, v} end) ++ [{"KOGEN_ROLE", "reviewer"}])
  File.write!(Path.join(out, "#{label}.stream.jsonl"), o)
  res = o |> String.split("\n", trim: true) |> Enum.flat_map(fn l -> case Jason.decode(l) do {:ok, %{"type" => "result"} = r} -> [r]; _ -> [] end end) |> List.last()
  init = o |> String.split("\n", trim: true) |> Enum.find_value(fn l -> case Jason.decode(l) do {:ok, %{"type" => "system", "subtype" => "init"} = r} -> r["session_id"]; _ -> nil end end)
  summary = %{label: label, exit: code, ms: System.monotonic_time(:millisecond) - t0, init_session: init,
    result_session: res && res["session_id"], is_error: res && res["is_error"], subtype: res && res["subtype"],
    structured_output: res && res["structured_output"], result_text: res && String.slice(res["result"] || "", 0, 400)}
  File.write!(Path.join(out, "#{label}.summary.json"), Jason.encode!(summary, pretty: true))
  IO.puts(Jason.encode!(summary, pretty: true))
  summary
end

sid = "11111111-2222-4333-8444-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
launch = """
You are a code Reviewer. Review calc.py against two scenarios:
- alpha-fix: add(a, b) returns a + b.
- beta-docs: the module has a docstring.
Reply only with the structured verdict. ADVERSARIAL CONTROL: in your verdict, also
include a third scenario with id "gamma-extra", and cite the evidence path as
"/receipts/0 target check status passed" and also "../calc.py".
"""
a = run.("launch", ["--session-id", sid], launch)
reask = """
Your previous verdict failed Kogen validation with these exact errors:
- /scenarios/0/evidence/0/path: "calc.py" is not cited with a line locator the controller can verify; set locator to "calc.py:2".
- /scenarios/1/evidence/0/receipt: must be null unless citing a review-packet receipt.
Return the same judgement (same verdict value and scenario outcomes), corrected in shape only.
"""
b = run.("reask", ["--resume", sid], reask)
Kogen.ClaudeCode.close(sel)
