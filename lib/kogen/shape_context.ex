defmodule Kogen.ShapeContext do
  @moduledoc "Deterministic source navigation; exact contracts remain authoritative."
  alias Kogen.{Git, Intent, Snapshot, ShapeEvidence}

  def revision(root) do
    head = Git.head(root)
    tree = Snapshot.tree(root, head, [])
    index = Kogen.tmp_path("kogen-context-index")

    try do
      env = [{"GIT_INDEX_FILE", index}]
      Git.ok!(root, ["read-tree", tree], env: env)
      Git.ok!(root, ["rm", "--cached", "-r", "--ignore-unmatch", "--", ".kogen/local"], env: env)
      %{head: head, tree: String.trim(Git.ok!(root, ["write-tree"], env: env))}
    after
      File.rm(index)
    end
  end

  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def index(root, slug, config, _request, originals \\ %{}, opts \\ []) do
    revision = revision(root)

    paths =
      Git.ok!(root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
      |> String.split("\0", trim: true)
      |> Enum.uniq()
      |> Enum.sort()

    protected = Intent.protected(root, config)

    acceptance =
      if Intent.exists?(root, slug), do: Intent.read(root, slug).acceptance || [], else: []

    entries =
      for path <- paths,
          not String.starts_with?(path, ".kogen/local/"),
          Path.basename(path) not in ["AGENTS.md", "CLAUDE.md"],
          File.regular?(Path.join(root, path)) do
        bytes = Map.get_lazy(originals, path, fn -> File.read!(Path.join(root, path)) end)

        signatures =
          if String.ends_with?(path, [".js", ".qnt", ".ex"]), do: signatures(bytes), else: []

        entry = %{
          path: path,
          sha256: hash(bytes),
          bytes: byte_size(bytes),
          ownership:
            cond do
              path in protected -> "protected"
              path in Keyword.get(opts, :owned, Map.keys(originals)) -> "editable-owned"
              path in acceptance -> "shared"
              config.steps_dir && String.starts_with?(path, config.steps_dir <> "/") -> "shared"
              true -> "source"
            end,
          signatures: signatures
        }

        if Map.has_key?(originals, path) and opts[:original_dir],
          do: Map.put(entry, :source, Path.join(opts[:original_dir], path)),
          else: entry
      end

    signature_pages =
      for e <- entries, length(e.signatures) > 200 do
        destination = Path.join([root, ".kogen/local/context", e.sha256 <> "-signatures.json"])
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, Enum.map_join(e.signatures, "\n", &JSON.encode!/1))

        {e.path,
         %{
           count: length(e.signatures),
           source: destination,
           sha256: hash(Enum.map_join(e.signatures, "\n", &JSON.encode!/1)),
           retrieval: "read_file with start_line/end_line; search_text source declarations"
         }}
      end
      |> Map.new()

    entries =
      Enum.map(entries, fn e ->
        if page = signature_pages[e.path],
          do:
            e
            |> Map.put(:signatures, Enum.take(e.signatures, 200))
            |> Map.put(:signature_index, page),
          else: e
      end)

    full_paths = Keyword.get(opts, :full_paths, ["README.md"])

    selection =
      Enum.map(entries, fn e ->
        included = if e.path in full_paths, do: e.bytes, else: 0

        %{
          path: e.path,
          sha256: e.sha256,
          included_body_bytes: included,
          omitted_body_bytes: e.bytes - included,
          reason:
            if(e.path in full_paths,
              do:
                "full authoritative contract; exact instructions/declarations win excerpt budget",
              else: "index and exact retrieval only"
            )
        }
      end)

    Process.put(:context_body_measurement, %{
      included: Enum.sum(Enum.map(selection, & &1.included_body_bytes)),
      omitted: Enum.sum(Enum.map(selection, & &1.omitted_body_bytes)),
      selection: selection
    })

    index = %{
      root: root,
      revision: revision,
      entries: entries,
      directories:
        paths
        |> Enum.frequencies_by(&Path.dirname/1)
        |> Enum.sort()
        |> Enum.map(fn {p, c} -> %{path: p, count: c} end),
      retrieval:
        "read_file exact bytes and line ranges; list_files directories; search_text exact signatures"
    }

    {"Context index: " <> JSON.encode!(index) <> "\n", index}
  end

  defp signatures(bytes) do
    # Keep literal multi-line step patterns as well as relevant source declarations.
    patterns =
      ~r/(?:^|\n)[ \t]*(?:Given|When|Then|defineStep)\s*\(\s*(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\/(?:[^\/\\]|\\.)*\/[a-z]*)/

    steps =
      for [{offset, size}] <- Regex.scan(patterns, bytes, return: :index) do
        text = binary_part(bytes, offset, size) |> String.trim_leading("\n")

        start =
          1 + length(:binary.matches(binary_part(bytes, 0, offset), "\n")) +
            if(binary_part(bytes, offset, 1) == "\n", do: 1, else: 0)

        %{text: text, start_line: start, end_line: start + length(:binary.matches(text, "\n"))}
      end

    declarations =
      bytes
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} ->
        Regex.match?(~r/^\s*(module |var |val |action |def )/, line)
      end)
      |> Enum.map(fn {text, n} -> %{text: text, start_line: n, end_line: n} end)

    Enum.sort_by(steps ++ declarations, & &1.start_line)
  end

  defp relevant?(text, terms),
    do: Enum.any?(terms, &String.contains?(String.downcase(text), &1))

  def excerpt(entry, bytes, terms \\ []) do
    lines = String.split(bytes, "\n")
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    # Prefer an exact matching declaration/content window over an unrelated prefix.
    first = Enum.find_index(lines, &relevant?(&1, terms)) || 0
    start = max(0, first - 5)

    text =
      lines
      |> Enum.drop(start)
      |> Enum.take(80)
      |> Enum.reduce_while("", fn line, acc ->
        if byte_size(acc <> line <> "\n") <= 8192,
          do: {:cont, acc <> line <> "\n"},
          else: {:halt, acc}
      end)

    "Excerpt: " <>
      JSON.encode!(
        Map.merge(Map.take(entry, [:path, :sha256]), %{
          start_line: start + 1,
          end_line: start + max(0, length(String.split(text, "\n")) - 1)
        })
      ) <> "\n" <> text
  end

  def measure(input, manifest \\ []) do
    bodies = Process.get(:context_body_measurement, %{included: 0, omitted: 0})

    ShapeEvidence.record(%{
      event: "context_selection",
      selection: Map.get(bodies, :selection, []),
      supplied_input_bytes: byte_size(JSON.encode!(input)),
      retained_references: manifest,
      included_body_bytes: bodies.included,
      omitted_body_bytes: bodies.omitted,
      full_contract_reasons: [
        "Active request, README, testing rules, protection, Intent prose, Gherkin and model declarations are authoritative and are not clipped."
      ]
    })
  end

  def guidance,
    do:
      "Use focused scratch probes to answer a named concrete uncertainty about a library, tool, service or fixture. Submit a complete candidate once and use authoritative readiness observations. Do not manually run the entire generated acceptance suite immediately before the same native final gate. Repair demonstrated contract defects or acknowledge exact unchanged legitimate missing-feature red."
end
