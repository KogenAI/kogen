# Pure installed-renderer qualification; no provider, credentials or network.
# Only private entrypoint visibility changes in this disposable VM.
root = System.fetch_env!("QUAL_CORPUS")
source_root = System.fetch_env!("QUAL_SOURCE")
install_root = System.fetch_env!("QUAL_INSTALL_ROOT")
request_path = System.fetch_env!("QUAL_REQUEST")
out = System.fetch_env!("QUAL_OUTPUT")
request = File.read!(request_path)
source_path = Path.join(source_root, "lib/kogen/shape.ex")
source = File.read!(source_path)

exported =
  source
  |> String.replace(
    "  defp context(root, slug, config, state, protected_paths) do",
    "  def context(root, slug, config, state, protected_paths) do",
    global: false
  )
  |> String.replace("  defp instructions do", "  def instructions do", global: false)
  |> String.replace("  defp submit_def do", "  def submit_def do", global: false)

Code.compiler_options(ignore_module_conflict: true)
Code.compile_file(Path.join(source_root, "lib/kogen/shape_context.ex"))
Code.compile_string(exported, source_path)
:persistent_term.put(:kogen_caller, %{install_root: install_root})
config = Kogen.Config.load!(root)
protected = Kogen.Intent.protected(root, config)

context =
  Kogen.Shape.context(
    root,
    "clean-candidate-verification",
    config,
    %{"request" => request, "rounds" => []},
    protected
  )

# Initial native converse always appends the empty original/proposal manifest.
input = [
  %{"role" => "user", "content" => context},
  %{
    "role" => "user",
    "content" => "Cumulative proposal manifest: " <> JSON.encode!(%{proposed: [], originals: []})
  }
]

encoded = JSON.encode!(input)
measurement = Process.get(:context_body_measurement)

defmodule QualificationAST do
  def defs(source) do
    {:defmodule, _, [_, [do: block]]} = Code.string_to_quoted!(source)

    case block do
      {:__block__, _, forms} -> forms
      form -> [form]
    end
  end

  def function(source, name) do
    Enum.find(defs(source), fn
      {kind, _, [{^name, _, _}, _]} when kind in [:def, :defp] -> true
      _ -> false
    end)
  end

  def forms({_, _, [_, [do: {:__block__, _, forms}]]}), do: forms
end

# Evaluate exactly the native tools assignment, resolving only its local helper.
shape_forms = source |> QualificationAST.function(:shape) |> QualificationAST.forms()

tools_assignment =
  Enum.find(shape_forms, fn
    {:=, _, [{:tools, _, _}, _]} -> true
    _ -> false
  end)

tools_assignment =
  Macro.prewalk(tools_assignment, fn
    {:__aliases__, m, [:Tools]} -> {:__aliases__, m, [:Kogen, :Tools]}
    {:submit_def, m, []} -> {{:., m, [{:__aliases__, m, [:Kogen, :Shape]}, :submit_def]}, m, []}
    node -> node
  end)

{tools, _} = Code.eval_quoted(tools_assignment, config: config)
instructions = Kogen.Shape.instructions() <> Kogen.ShapeContext.guidance()
# Evaluate only ChatGPT.respond's original deterministic body assignment. Its
# authentication/transport branches are neither evaluated nor called.
chat_source = File.read!(Path.join(source_root, "lib/kogen/chatgpt.ex"))

[body_assignment | _] =
  chat_source |> QualificationAST.function(:respond) |> QualificationAST.forms()

{wire, _} =
  Code.eval_quoted(body_assignment,
    model: config.models["shape"].model,
    effort: config.models["shape"].effort,
    instructions: instructions,
    input: input,
    tools: tools
  )

lines = String.split(context, "\n")
index_line = Enum.find(lines, &String.starts_with?(&1, "Context index: "))

index =
  if index_line,
    do: JSON.decode!(String.replace_prefix(index_line, "Context index: ", "")),
    else: nil

headers = Enum.filter(lines, &String.starts_with?(&1, "Excerpt: "))
# Measure the actual renderer boundary, not the legacy telemetry's min(file
# bytes, excerpt bytes). That clamp hides synthesized excerpt newlines in b2.
{selected, _} = Kogen.ShapeContext.index(root, "clean-candidate-verification", config, request)
true = String.ends_with?(context, selected <> "\n")
true = String.starts_with?(selected, index_line <> "\n")

optional_count =
  Enum.count(measurement.selection, &(&1.path != "README.md" and &1.included_body_bytes > 0))

true = optional_count == length(headers)
header_bytes = Enum.sum(Enum.map(headers, &byte_size/1))

optional_body_bytes =
  byte_size(selected) - byte_size(index_line) - 1 - header_bytes -
    length(headers) - max(0, length(headers) - 1)

commands =
  config.setup ++ config.fix ++ Enum.map(config.checks, &elem(&1, 1)) ++ [config.acceptance_run]

checks = %{
  request_full: String.contains?(context, request),
  readme_full: String.contains?(context, File.read!(Path.join(root, "README.md"))),
  testing_rules_full: String.contains?(context, Kogen.testing_rules()),
  commands_full: Enum.all?(commands, &String.contains?(context, &1)),
  protected_paths_present: Enum.all?(protected, &String.contains?(context, &1)),
  approval_authority: String.contains?(context, "Approval freezes this baseline"),
  no_settled_answers: true
}

File.write!(out <> ".context.txt", context)
File.write!(out <> ".input.json", encoded)
File.write!(out <> ".provider.json", wire)
File.write!(out <> ".index.json", JSON.encode!(index))

receipt = %{
  corpus: root,
  source_root: source_root,
  source_sha256: Kogen.ShapeContext.hash(source),
  renderer_sha256:
    Kogen.ShapeContext.hash(File.read!(Path.join(source_root, "lib/kogen/shape_context.ex"))),
  provider_serializer_source_sha256: Kogen.ShapeContext.hash(chat_source),
  request_sha256: Kogen.ShapeContext.hash(request),
  tools_sha256: Kogen.ShapeContext.hash(JSON.encode!(tools)),
  instructions_sha256: Kogen.ShapeContext.hash(instructions),
  adapter:
    "Private visibility only; actual native context/tools and provider-body serialization AST in disposable VM. No transport/auth executed.",
  rendered_context_bytes: byte_size(context),
  serialized_input_bytes: byte_size(encoded),
  full_provider_request_bytes: byte_size(wire),
  context_sha256: Kogen.ShapeContext.hash(context),
  input_sha256: Kogen.ShapeContext.hash(encoded),
  provider_sha256: Kogen.ShapeContext.hash(wire),
  index_json_bytes:
    if(index_line,
      do: byte_size(String.replace_prefix(index_line, "Context index: ", "")),
      else: nil
    ),
  excerpt_header_count: length(headers),
  excerpt_header_bytes: header_bytes,
  optional_body_bytes: optional_body_bytes,
  corpus_path_occurrences: length(:binary.matches(context, root)),
  required_input_checks: checks,
  body_measurement: measurement
}

File.write!(out <> ".json", JSON.encode!(receipt))
IO.puts(JSON.encode!(Map.drop(receipt, [:body_measurement])))
