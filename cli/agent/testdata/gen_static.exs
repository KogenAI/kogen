# Generates prompts_golden.json (byte count and SHA-256 of every prompt as the Elixir Kogen
# returns it) and defs_golden.json (every tool definition as Kogen.Tools.defs/1 and the
# submit_* definitions return it).
#
#   cd <repo root> && mise exec -- mix run --no-start cli/agent/testdata/gen_static.exs cli/agent/testdata
#
[dir] = System.argv()

# Some of the Elixir functions are private: compile a copy of the module that exports them.
variant = fn file, mod, fun, args ->
  src =
    File.read!(file)
    |> String.replace("defmodule #{mod} do", "defmodule #{mod}Dump do", global: false)
    |> String.replace("defp #{fun}(", "def #{fun}(")
    |> String.replace("defp #{fun} do", "def #{fun} do")

  Code.put_compiler_option(:ignore_module_conflict, true)
  Code.compile_string(src, file)
  apply(Module.concat([mod <> "Dump"]), String.to_atom(fun), args)
end

hash = fn text -> :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) end

prompts = %{
  "builder" => variant.("lib/kogen/build.ex", "Kogen.Build", "builder_instructions", []),
  "reviewer" => variant.("lib/kogen/review.ex", "Kogen.Review", "instructions", []),
  "shaper" => variant.("lib/kogen/shape.ex", "Kogen.Shape", "instructions", []),
  "refine" => variant.("lib/kogen/refine.ex", "Kogen.Refine", "instructions", []),
  "init" => variant.("lib/kogen/init.ex", "Kogen.Init", "instructions", []),
  "shaper-context-guidance" => Kogen.ShapeContext.guidance(),
  "readiness-acknowledgment-guidance" => Kogen.Readiness.acknowledgment_guidance(),
  "feasibility-guidance" => Kogen.Feasibility.guidance(),
  "testing-rules" => File.read!("docs/testing-rules.md")
}

golden = Map.new(prompts, fn {k, v} -> {k, %{"bytes" => byte_size(v), "sha256" => hash.(v)}} end)
File.write!(Path.join(dir, "prompts_golden.json"), JSON.encode!(golden) <> "\n")

names = ~w(shell view_image read_file write_file report_blocker finish list_files search_text probe documentation)

defs =
  Map.new(names, fn n -> {n, hd(Kogen.Tools.defs([n]))} end)
  |> Map.put("submit", variant.("lib/kogen/shape.ex", "Kogen.Shape", "submit_def", []))
  |> Map.put("submit_review", variant.("lib/kogen/review.ex", "Kogen.Review", "submit_def", []))
  |> Map.put("submit_refinement", variant.("lib/kogen/refine.ex", "Kogen.Refine", "submit_def", []))
  |> Map.put("submit_configuration", variant.("lib/kogen/init.ex", "Kogen.Init", "submit_def", []))
  |> Map.put("shape_batch", Kogen.ShapeBatch.definition())
  |> Map.put(
    "worker_result",
    List.last(variant.("lib/kogen/shape_batch.ex", "Kogen.ShapeBatch", "tools", ["draft"]))
  )

File.write!(Path.join(dir, "defs_golden.json"), JSON.encode!(defs) <> "\n")
IO.puts("wrote #{map_size(golden)} prompts and #{map_size(defs)} definitions")

# Kogen.Tools.cut: each case is `unit` (base64) repeated `n` times.
cuts = [
  {"short", "x", 10},
  {"limit-1", "x", 16_383},
  {"limit", "x", 16_384},
  {"limit+1", "x", 16_385},
  {"20000 ascii", "x", 20_000},
  {"2-byte chars", "é", 10_000},
  {"3-byte chars", "€", 7_000},
  {"4-byte chars", "😀", 5_000},
  {"lines", "line of text\n", 4_000},
  {"invalid byte", <<0xFF>>, 20_000},
  {"invalid then valid", <<0xFF, ?a>>, 10_000},
  {"1 MB", "0123456789abcdef", 65_536},
  {"digits grow", "y", 99_999},
  {"digits grow 2", "y", 1_000_000}
]

cut_golden =
  for {name, unit, n} <- cuts do
    text = String.duplicate(unit, n)
    cut = Kogen.Tools.cut(text)

    %{
      "name" => name,
      "unit" => Base.encode64(unit),
      "n" => n,
      "bytes" => byte_size(cut),
      "sha256" => hash.(cut),
      "head" => binary_part(cut, 0, min(byte_size(cut), 60)) |> Base.encode64(),
      "marker" => case Regex.run(~r/\n\[\.\.\. \d+ bytes omitted \.\.\.\]\n/, cut) do
        [m] -> m
        _ -> nil
      end
    }
  end

File.write!(Path.join(dir, "cut_golden.json"), "[\n" <> Enum.map_join(cut_golden, ",\n", &JSON.encode!/1) <> "\n]\n")
