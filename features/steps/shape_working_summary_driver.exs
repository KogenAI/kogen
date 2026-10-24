defmodule ShapeWorkingSummaryDriver do
  alias Kogen.{ChatGPT, ShapeWorkingContext, RefineWorkingContext, WorkingContext, Tools}

  def hash(term), do: WorkingContext.hash(JSON.encode!(term))
  def mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o777)
  def measure(sh, items), do: WorkingContext.measure(ChatGPT.request_body(sh.role, "local summary fixture policy", items, []))

  def prepare(sh, owner, input, spec) do
    if owner == "shape" do
      ShapeWorkingContext.prepare(sh, input, spec["invalid_submissions"], spec["manifest"], "local summary fixture policy")
    else
      RefineWorkingContext.prepare(sh, sh.role, [], input, spec["invalid_submissions"], spec["manifest"], "local summary fixture policy")
    end
  end

  def snapshot(ref) when is_map(ref) do
    case File.read(ref["path"] || "") do
      {:ok, bytes} ->
        %{ref: ref, sha256: WorkingContext.hash(bytes), mode: mode(ref["path"]), dir_mode: mode(Path.dirname(ref["path"])), records: String.split(bytes, "\n", trim: true) |> Enum.map(&JSON.decode!/1)}
      _ -> %{ref: ref, records: nil}
    end
  end
  def snapshot(_), do: %{ref: nil, records: nil}

  def old_batch(n, spec) do
    calls = for j <- 1..spec["old_batch_calls"] do
      %{"type" => "function_call", "id" => "old-fc-#{n}-#{j}", "call_id" => "old-#{n}-#{j}", "name" => "read_file", "arguments" => "{}"}
    end
    calls ++ Enum.map(calls, fn c ->
      %{"type" => "function_call_output", "call_id" => c["call_id"], "output" => Tools.cut(String.duplicate("x", spec["tool_result_limit"]))}
    end)
  end

  def damage(sh, owner, reduced, spec, ref) when is_map(ref) do
    p = ref["path"]
    original = File.read!(p)
    for kind <- ["changed", "missing", "symlink", "mode"] do
      case kind do
        "changed" -> File.write!(p, original <> " ")
        "missing" -> File.rm!(p)
        "symlink" ->
          File.write!(p <> ".replacement", original)
          File.rm!(p)
          File.ln_s!(p <> ".replacement", p)
        "mode" -> File.chmod!(p, 0o644)
      end
      before_files = Path.wildcard(Path.join(sh.working_context.dir, "*"))
      code = try do
        prepare(sh, owner, reduced, spec)
        "accepted"
      rescue
        e in Kogen.Error -> e.class <> "/" <> e.reason
      end
      after_files = Path.wildcard(Path.join(sh.working_context.dir, "*"))
      File.rm(p)
      File.write!(p, original)
      File.chmod!(p, 0o600)
      File.rm(p <> ".replacement")
      %{kind: kind, code: code, no_new_archive: before_files == after_files}
    end
  end
  def damage(_, _, _, _, _), do: []

  def main(input_path, output_path) do
    fixture = JSON.decode!(File.read!(input_path))
    owner = fixture["owner"]
    spec = fixture["s"]
    mandatory = fixture["mandatory"]
    root = Kogen.tmp_path("working-summary")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    try do
      sh = %{root: root, evidence: Path.join(root, ".kogen/local/refinements/fixture"), role: %{model: "fixture", effort: "high"}, tools: [], docs: fixture["docs"], inspected: true, declared_steps: spec["declared_steps"], ready: nil, observed: nil, originals: %{}, allowed: spec["ownership"], started_at: System.monotonic_time(:millisecond)}
      state = if owner == "shape", do: ShapeWorkingContext.new(root, "fixture", mandatory), else: RefineWorkingContext.new(sh, mandatory)
      state = if owner == "refine", do: %{state | documentation: fixture["docs"]}, else: state
      sh = Map.put(sh, :working_context, state)
      {sh, reduced, samples} = fixture["exchanges"] |> Enum.with_index(1) |> Enum.reduce({sh, mandatory, []}, fn {exchange, n}, {sh, active, samples} ->
        input = active ++ old_batch(n, spec) ++ exchange
        before = measure(sh, input)
        {sh, reduced} = prepare(sh, owner, input, spec)
        ref = List.last(sh.working_context.history)
        bytes = File.read!(ref["path"])
        archive = JSON.decode!(bytes)
        after_size = measure(sh, reduced)
        sample = %{reduced: reduced, before_bytes: before.rendered_bytes, after_bytes: after_size.rendered_bytes, reserve: after_size.output_reserve_tokens, expected_input_hash: hash(input), archive: %{ref: ref, sha256: WorkingContext.hash(bytes), mode: mode(ref["path"]), dir_mode: mode(Path.dirname(ref["path"])), version: archive["version"], owner: archive["owner"], previous: archive["previous"], documentation: archive["documentation"], input_hash: hash(archive["input"])}, snapshot: snapshot(archive["documentation"])}
        {sh, reduced, samples ++ [sample]}
      end)
      final_ref = List.last(samples).snapshot.ref
      retrieved = if is_map(final_ref) do
        for i <- Enum.with_index(fixture["docs"], 1) |> Enum.map(&elem(&1, 1)) do
          Tools.run("read_file", %{"path" => final_ref["path"], "start_line" => i, "end_line" => i}, %{root: root, protected: [], tools: ["read_file"]}) |> Tools.cut()
        end
      else
        []
      end
      first_ref = hd(samples).snapshot.ref
      result = %{owner: owner, samples: samples, native_history_count: length(sh.working_context.history), native_documentation: if(owner == "shape", do: sh.docs, else: sh.working_context.documentation), retrieved: retrieved, damage: damage(sh, owner, reduced, spec, first_ref)}
      File.write!(output_path, JSON.encode!(result))
    after
      File.rm_rf!(root)
    end
  end
end

[input, output] = System.argv()
ShapeWorkingSummaryDriver.main(input, output)
