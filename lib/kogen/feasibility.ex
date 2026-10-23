defmodule Kogen.Feasibility do
  @moduledoc "Declared, targeted Shape evidence, bound to final file bytes."
  def guidance do
    ~S"""
    Declared shaping evidence is optional and selected by shaping judgment, not a universal registry or coverage claim. Before expensive implementation, identify genuinely uncertain outcome-critical dependencies. Probe the actual proposed request on its supported target route, authentication scope and model, or use a real relevant local fixture; a working old driver or exclusion-list silence does not prove a changed request. Distinguish observed support, explicit rejection and untested uncertainty. Unsupported requests need an honest supported outcome/fallback or clarification of a material UX choice. No blanket paid probes or endpoint sweep.

    In `## Feasibility`, add one single-line JSON bullet per explicit obligation, for example:
    `- evidence: {"id":"route","kind":"capability","inputs":["route.json","route.cjs"],"observers":[],"checks":[{"name":"support","command":"node route.cjs","exit":23,"output":"explicit rejection\n"}]}`
    Ids are unique. Paths name exact repository-relative regular files, including local executable fixtures. A capability has one `support` check. A generated risky protected fixture/driver (multiple assertions, scripted transport replay, subprocess generation, or lifecycle-sensitive evidence) must declare and run final-byte observer controls in Feasibility. Controls must reach deeper assertions independently of masked missing-feature red. This is shaping judgment, not a universal registry or source-code heuristic. Simple local work without such risk needs no probes. An observer names the final generated protected observer file(s) in `observers` and has exactly two checks in order, `good` and `bad`: those same observer bytes must accept the known-good fixture and reject the known-bad fixture. Observer good must expect exit 0; bad must expect a NONZERO integer exit. Capability support may legitimately expect nonzero. Every check declares a shell command, expected integer exit and exact combined output string. Nonzero expected exit is legitimate observed rejection; timeout never discharges an obligation. These are small targeted controls, not product implementation or a second acceptance suite. Scratch overlays can explore, but final proof identifies submitted final formatted input/observer bytes. Fresh actual evidence can qualify only identical commands, bytes and outcomes. Narrative, fabricated records, model-only green and missing-feature red cannot qualify a declaration. Readiness executes outstanding checks and retains actual mismatches. Exact red acknowledgment cannot waive an unsatisfied obligation; ordinary no-obligation work needs no probes.

    Preserve the complete original request, settled scope and supplied reproducing examples and counterexamples in executable acceptance, not only prose. Do not narrow whole-UI requests to one section or substitute an unconsumed prior-candidate pointer. Advice, proposals and host observations are lower-authority evidence, not product authority. Qualify risky protected observers using actual known-good and known-bad controls even when an earlier missing-feature failure masks them; baseline need not pass the unimplemented feature. Ground fixture/history actors in actual seed output; observe Search before resetting it; compare rendered HTML to rendered expectations, not raw Markdown; account for computed OKLCH rather than assuming RGB; distinguish compiler/process diagnostics from rendered payload; compare JSON objects semantically while preserving meaningful array and string order. A broken fixture is not legitimate product red.

    A protected contradiction is a BUILDER-REPORTED, unproven stop, not authority to change the approved contract. Ordinary implementation failures return to the builder. For a stopped candidate/build_blocked Build, explicit `kogen intent recover <build-id> --output <new-external-directory>` preserves production and clears only its recorded implementation delta without inference, reapproval, resume, import or old-green reuse. Independently investigate the generated correction.md through normal Refine readiness using the ORIGINAL full contract hash; successful Refine revokes old approval. Require fresh exact human approval and a production-clean fresh Build with context.md, full normal verification and independent final-tree review. Observe long work through read-only context/inspect; do not poll, automatically retry or cancel unrelated work. Authentication/resource/startup failures remain honest stops.

    Native shell/read_file tools remain text-only; explicit view_image alone delivers bounded typed PNG pixels. DOM/action/data/contrast/overflow predicates, screenshot paths and exports do not establish actual pixel interpretation or visual approval. Distinguish successful selection, completed delivery, explicit fallible observations and required human/designer decisions. Retain a truthful external pixel-review handoff when native input is unavailable or refused.
    """
  end

  alias Kogen.{Error, ShapeEvidence, Tools}

  def declarations(intent) do
    entries =
      for line <- intent.feasibility || [], String.starts_with?(line, "- evidence:") do
        case JSON.decode(String.trim(String.replace_prefix(line, "- evidence:", ""))) do
          {:ok, d} -> validate!(d, intent)
          _ -> invalid!("invalid evidence JSON")
        end
      end

    ids = Enum.map(entries, & &1["id"])
    if Enum.uniq(ids) != ids, do: invalid!("evidence ids must be unique")
    entries
  end

  defp validate!(d, intent) do
    unless is_map(d) and is_binary(d["id"]) and d["id"] != "" and
             d["kind"] in ["capability", "observer"] and paths?(d["inputs"]) and
             paths?(d["observers"]) and is_list(d["checks"]),
           do: invalid!("invalid evidence declaration")

    names = if d["kind"] == "capability", do: ["support"], else: ["good", "bad"]

    unless Enum.all?(d["checks"], &is_map/1) and
             Enum.map(d["checks"], & &1["name"]) == names and
             Enum.all?(d["checks"], fn c ->
               is_binary(c["command"]) and String.trim(c["command"]) != "" and
                 is_integer(c["exit"]) and is_binary(c["output"])
             end) and
             if(d["kind"] == "capability",
               do: d["observers"] == [],
               else:
                 d["observers"] != [] and Enum.all?(d["observers"], &(&1 in intent.acceptance))
             ),
           do: invalid!("#{d["id"]}: invalid evidence checks or observers")

    if d["kind"] == "observer" do
      [good, bad] = d["checks"]

      unless good["exit"] == 0 and bad["exit"] != 0,
        do:
          invalid!("#{d["id"]}: observer good must expect exit 0 and bad a NONZERO integer exit")
    end

    d
  end

  defp paths?(paths) do
    is_list(paths) and Enum.uniq(paths) == paths and
      Enum.all?(paths, fn p ->
        is_binary(p) and p != "" and Path.type(p) == :relative and
          not Enum.any?(Path.split(p), &(&1 in ["..", "."]))
      end)
  end

  defp invalid!(detail),
    do: Error.raise!("intent", "not_ready", "invalid feasibility evidence", 1, [detail])

  defp identities(root, paths) do
    Map.new(paths, fn p ->
      path = Path.join(root, p)

      unless Enum.all?(Enum.scan(Path.split(p), root, &Path.join(&2, &1)), fn part ->
               case File.lstat(part) do
                 {:ok, %{type: type}} -> type != :symlink
                 _ -> false
               end
             end) and File.regular?(path),
             do: invalid!("evidence input #{p} must be a repository-relative regular file")

      {p, Kogen.ShapeContext.hash(File.read!(path))}
    end)
  end

  defp identity(root, d) do
    %{
      "id" => d["id"],
      "kind" => d["kind"],
      "inputs" => identities(root, d["inputs"]),
      "observers" => identities(root, d["observers"])
    }
  end

  def valid?(root, intent, proof) do
    ds = declarations(intent)

    if ds == [] do
      proof in [nil, []]
    else
      is_list(proof) and length(ds) == length(proof) and
        Enum.zip(ds, proof)
        |> Enum.all?(fn {d, p} ->
          is_map(p) and Map.drop(p, ["checks"]) == identity(root, d) and
            p["checks"] == Enum.map(d["checks"], &Map.put(&1, "timed_out", false))
        end)
    end
  rescue
    _ in Error -> false
  end

  def execute!(root, intent, evidence_root) do
    results =
      Enum.map(declarations(intent), fn d ->
        id = identity(root, d)

        checks =
          Enum.map(d["checks"], fn c ->
            r =
              ShapeEvidence.probe(fn ->
                Tools.probe_result(c["command"], [], %{
                  root: root,
                  evidence_inputs: Map.merge(id["inputs"], id["observers"])
                })
              end)

            actual = %{
              "name" => c["name"],
              "command" => c["command"],
              "exit" => r.status,
              "timed_out" => r.timed_out,
              "output" => r.output
            }

            actual =
              if Map.has_key?(r, :input_changes),
                do: Map.put(actual, "input_changes", r.input_changes),
                else: actual

            ShapeEvidence.record(%{event: "feasibility_check", obligation: id, check: actual})
            actual
          end)

        Map.put(id, "checks", checks)
      end)

    if results != [] do
      path = Path.join(evidence_root, ".kogen/local/readiness/#{intent.slug}-feasibility.ndjson")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(results) <> "\n", [:append])
    end

    unless valid?(root, intent, results) do
      problems =
        for {d, p} <- Enum.zip(declarations(intent), results),
            {expected, actual} <- Enum.zip(d["checks"], p["checks"]),
            Map.put(expected, "timed_out", false) != actual do
          "#{d["id"]}/#{expected["name"]}: expected #{JSON.encode!(expected)}; actual #{JSON.encode!(actual)}"
        end

      problems = problems |> Enum.join("\n") |> Tools.cut() |> String.split("\n")
      Error.raise!("intent", "not_ready", "declared feasibility evidence failed", 1, problems)
    end

    results
  end
end
