# Writes cli/verify/testdata/golden/feasibility.json: what Kogen.Feasibility.declarations/1
# and valid?/3 and Kogen.Readiness.observations/3 and acknowledgment/3 (the Elixir
# reference) give for fixed inputs.
#
#   cd <repo> && mise exec -- mix run --no-start cli/verify/testdata/gen/feasibility.exs

alias Kogen.{Feasibility, Intent, Readiness}

capability = fn id, inputs, extra ->
  %{
    "id" => id,
    "kind" => "capability",
    "inputs" => inputs,
    "observers" => [],
    "checks" => [Map.merge(%{"name" => "support", "command" => "node route.cjs", "exit" => 23, "output" => "explicit rejection\n"}, extra)]
  }
end

observer = fn id ->
  %{
    "id" => id,
    "kind" => "observer",
    "inputs" => ["fixture.txt"],
    "observers" => ["observer.cjs"],
    "checks" => [
      %{"name" => "good", "command" => "node observer.cjs good", "exit" => 0, "output" => "accepted\n"},
      %{"name" => "bad", "command" => "node observer.cjs bad", "exit" => 1, "output" => "rejected\n"}
    ]
  }
end

line = fn d -> "- evidence: " <> JSON.encode!(d) end
base = capability.("route", ["route.cjs"], %{})
put = fn d, k, v -> Map.put(d, k, v) end
check = fn d, f -> %{d | "checks" => Enum.map(d["checks"], f)} end

decl_inputs = [
  {"valid capability", [line.(base)]},
  {"valid observer", [line.(observer.("o"))]},
  {"no evidence bullets", ["- none"]},
  {"other bullets ignored", ["- Evidence: x", "- evidence-ish: y", "- none"]},
  {"no space after colon", ["- evidence:" <> JSON.encode!(base)]},
  {"two valid", [line.(base), line.(observer.("o"))]},
  {"invalid json", ["- evidence: {nope"]},
  {"json array", ["- evidence: []"]},
  {"json number", ["- evidence: 7"]},
  {"json null", ["- evidence: null"]},
  {"trailing garbage", [line.(base) <> " x"]},
  {"empty after prefix", ["- evidence:"]},
  {"missing id", [line.(Map.delete(base, "id"))]},
  {"empty id", [line.(put.(base, "id", ""))]},
  {"numeric id", [line.(put.(base, "id", 3))]},
  {"bad kind", [line.(put.(base, "kind", "probe"))]},
  {"inputs not a list", [line.(put.(base, "inputs", "route.cjs"))]},
  {"inputs missing", [line.(Map.delete(base, "inputs"))]},
  {"observers missing", [line.(Map.delete(base, "observers"))]},
  {"absolute path", [line.(put.(base, "inputs", ["/etc/passwd"]))]},
  {"dot dot path", [line.(put.(base, "inputs", ["a/../b"]))]},
  {"dot path", [line.(put.(base, "inputs", ["./route.cjs"]))]},
  {"empty path", [line.(put.(base, "inputs", [""]))]},
  {"duplicate inputs", [line.(put.(base, "inputs", ["a", "a"]))]},
  {"path not string", [line.(put.(base, "inputs", [1]))]},
  {"capability with observers", [line.(put.(base, "observers", ["observer.cjs"]))]},
  {"observer without observers", [line.(%{observer.("o") | "observers" => []})]},
  {"observer outside acceptance", [line.(%{observer.("o") | "observers" => ["other.cjs"]})]},
  {"observer wrong order", [line.(%{observer.("o") | "checks" => Enum.reverse(observer.("o")["checks"])})]},
  {"observer one check", [line.(%{observer.("o") | "checks" => [hd(observer.("o")["checks"])]})]},
  {"capability wrong name", [line.(check.(base, &Map.put(&1, "name", "good")))]},
  {"capability two checks", [line.(put.(base, "checks", base["checks"] ++ base["checks"]))]},
  {"checks not a list", [line.(put.(base, "checks", "x"))]},
  {"check not a map", [line.(put.(base, "checks", ["x"]))]},
  {"blank command", [line.(check.(base, &Map.put(&1, "command", "  ")))]},
  {"command not string", [line.(check.(base, &Map.put(&1, "command", 5)))]},
  {"exit float", ["- evidence: " <> String.replace(JSON.encode!(base), "\"exit\":23", "\"exit\":23.0")]},
  {"exit string", [line.(check.(base, &Map.put(&1, "exit", "23")))]},
  {"exit missing", [line.(check.(base, &Map.delete(&1, "exit")))]},
  {"output missing", [line.(check.(base, &Map.delete(&1, "output")))]},
  {"output not string", [line.(check.(base, &Map.put(&1, "output", 1)))]},
  {"check with extra key", [line.(check.(base, &Map.put(&1, "timeout", 3)))]},
  {"declaration with extra key", [line.(put.(base, "note", "x"))]},
  {"duplicate ids", [line.(base), line.(capability.("route", ["x"], %{}))]},
  {"negative exit", [line.(check.(base, &Map.put(&1, "exit", -1)))]},
  {"unicode output", [line.(check.(base, &Map.put(&1, "output", "é\u2028\n\t\"\\")))]}
]

declarations =
  for {name, lines} <- decl_inputs do
    intent = %Intent{slug: "controls", acceptance: ["observer.cjs"], feasibility: lines}

    try do
      %{"name" => name, "feasibility" => lines, "acceptance" => ["observer.cjs"], "ok" => Feasibility.declarations(intent)}
    rescue
      e in Kogen.Error -> %{"name" => name, "feasibility" => lines, "acceptance" => ["observer.cjs"], "error" => %{"detail" => e.detail, "lines" => e.lines, "class" => e.class, "reason" => e.reason, "exit" => e.exit}}
    end
  end

# valid?/3 with files on disk
hash = &Kogen.ShapeContext.hash/1
tc = fn d -> Enum.map(d["checks"], &Map.put(&1, "timed_out", false)) end

obligation = fn d, inputs, observers ->
  %{"id" => d["id"], "kind" => d["kind"], "inputs" => inputs, "observers" => observers, "checks" => tc.(d)}
end

route_files = %{"route.cjs" => "original"}
obs_files = %{"fixture.txt" => "good-and-bad", "observer.cjs" => "observer bytes"}
good = obligation.(base, %{"route.cjs" => hash.("original")}, %{})
obs = observer.("o")
good_obs = obligation.(obs, %{"fixture.txt" => hash.("good-and-bad")}, %{"observer.cjs" => hash.("observer bytes")})

with_check = fn o, f -> %{o | "checks" => Enum.map(o["checks"], f)} end

valid_cases = [
  {"exact", [base], route_files, [good]},
  {"nil proof", [base], route_files, nil},
  {"empty proof", [base], route_files, []},
  {"no declarations nil", [], %{}, nil},
  {"no declarations empty", [], %{}, []},
  {"no declarations with proof", [], route_files, [good]},
  {"exit differs", [base], route_files, [with_check.(good, &Map.put(&1, "exit", 0))]},
  {"timed out", [base], route_files, [with_check.(good, &Map.put(&1, "timed_out", true))]},
  {"output differs", [base], route_files, [with_check.(good, &Map.put(&1, "output", "supported\n"))]},
  {"command differs", [base], route_files, [with_check.(good, &Map.put(&1, "command", "old driver"))]},
  {"name differs", [base], route_files, [with_check.(good, &Map.put(&1, "name", "other"))]},
  {"input_changes present", [base], route_files, [with_check.(good, &Map.put(&1, "input_changes", ["route.cjs"]))]},
  {"timed_out missing", [base], route_files, [with_check.(good, &Map.delete(&1, "timed_out"))]},
  {"id differs", [base], route_files, [%{good | "id" => "other"}]},
  {"kind differs", [base], route_files, [%{good | "kind" => "observer"}]},
  {"input hash differs", [base], route_files, [%{good | "inputs" => %{"route.cjs" => hash.("changed")}}]},
  {"extra input", [base], route_files, [%{good | "inputs" => %{"route.cjs" => hash.("original"), "x" => "y"}}]},
  {"observers not empty", [base], route_files, [%{good | "observers" => %{"a" => "b"}}]},
  {"file changed", [base], %{"route.cjs" => "changed"}, [good]},
  {"file missing", [base], %{}, [good]},
  {"file is a symlink", [base], %{"route.cjs" => {:symlink, "elsewhere"}}, [good]},
  {"file in a symlinked dir", [capability.("route", ["dir/route.cjs"], %{})], %{"dir" => {:symlink, "real"}, "real/route.cjs" => "original"}, [obligation.(capability.("route", ["dir/route.cjs"], %{}), %{"dir/route.cjs" => hash.("original")}, %{})]},
  {"file in a directory", [capability.("route", ["dir/route.cjs"], %{})], %{"dir/route.cjs" => "original"}, [obligation.(capability.("route", ["dir/route.cjs"], %{}), %{"dir/route.cjs" => hash.("original")}, %{})]},
  {"proof not a list", [base], route_files, %{"x" => 1}},
  {"proof element not a map", [base], route_files, ["x"]},
  {"too many obligations", [base], route_files, [good, good]},
  {"observer exact", [obs], obs_files, [good_obs]},
  {"observer bytes changed", [obs], %{obs_files | "observer.cjs" => "weakened"}, [good_obs]},
  {"two declarations in order", [base, obs], Map.merge(route_files, obs_files), [good, good_obs]},
  {"two declarations swapped", [base, obs], Map.merge(route_files, obs_files), [good_obs, good]},
  {"invalid declaration", [Map.delete(base, "id")], route_files, [good]},
  {"declaration with extra check key", [with_check.(base, &Map.put(&1, "timeout", 3))], route_files, [good]}
]

valid =
  for {name, ds, files, proof} <- valid_cases do
    root = Path.join(System.tmp_dir!(), "kogen-golden-feas-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    for {path, content} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))

      case content do
        {:symlink, target} -> File.ln_s!(target, full)
        text -> File.write!(full, text)
      end
    end

    intent = %Intent{slug: "controls", acceptance: ["observer.cjs"], feasibility: Enum.map(ds, line)}
    ok = Feasibility.valid?(root, intent, proof)
    File.rm_rf!(root)

    files_json = Map.new(files, fn {p, c} -> {p, if(is_tuple(c), do: %{"symlink" => elem(c, 1)}, else: c)} end)

    %{"name" => name, "feasibility" => Enum.map(ds, line), "acceptance" => ["observer.cjs"], "files" => files_json, "proof" => proof, "valid" => ok}
  end

# observations and acknowledgment
scen = fn name, line, status, detail -> %{name: name, line: line, status: status, detail: detail} end
sha = String.duplicate("b", 64)
head = String.duplicate("c", 40)
ready = fn scenarios, exit -> %{scenarios: scenarios, sha256: sha, head: head, acceptance_exit: exit} end

obs_cases = [
  {"passing", ready.([scen.("A", 2, "passed", nil)], 0), nil},
  {"one failed", ready.([scen.("A", 2, "failed", "acceptance.feature line 3: Then x\nboom"), scen.("B", 5, "passed", nil)], 1), nil},
  {"failed without detail", ready.([scen.("A", 2, "failed", nil)], 1), nil},
  {"two failed", ready.([scen.("A", 2, "failed", "d1"), scen.("B", 5, "failed", "d2\nd2b")], 1), nil},
  {"custom reference", ready.([scen.("A", 2, "failed", "d1")], 1), "evidence/custom.json"},
  {"hook failure with é", ready.([scen.("A", 2, "failed", "a hook at features/steps/s.js line 9\n" <> String.duplicate("é", 11_000))], 1), nil},
  {"many failures", ready.(for(i <- 1..40, do: scen.("S#{i}", i, "failed", String.duplicate("x", 600))), 1), nil}
]

observations =
  for {name, r, ref} <- obs_cases do
    %{
      "name" => name,
      "ready" => %{"sha256" => sha, "head" => head, "acceptance_exit" => r.acceptance_exit, "scenarios" => Enum.map(r.scenarios, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))},
      "reference" => ref,
      "observations" => Readiness.observations("obs", r, ref),
      "acknowledgment" => Readiness.acknowledgment("obs", r, ref)
    }
  end

File.write!(
  Path.join(File.cwd!(), "cli/verify/testdata/golden/feasibility.json"),
  JSON.encode!(%{"declarations" => declarations, "valid" => valid, "observations" => observations}) <> "\n"
)

IO.puts("#{length(declarations)} declarations, #{length(valid)} valid, #{length(observations)} observations")
