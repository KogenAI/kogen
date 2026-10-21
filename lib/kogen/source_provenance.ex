defmodule Kogen.SourceProvenance do
  @moduledoc "Private successful source receipts; diagnostic data, never implementation authority."
  alias Kogen.{Intent, Git, Config, Error, WorkingContext}
  def path(root, slug), do: Path.join(root, ".kogen/local/provenance/#{slug}/current.json")

  def request(text, path),
    do: %{"text" => text, "source_path" => path || "-", "sha256" => WorkingContext.hash(text)}

  def comparison(root, slug) do
    text = File.read!(Path.join(root, Intent.intent_md(slug)))

    case Regex.run(~r/^## Source comparison[^\S\n]*\n(.*?)(?=\n## |\z)/ms, text) do
      [_, report] ->
        report = String.trim(report)

        if report == "" or byte_size(report) > 8192 do
          comparison_required!()
        end

        report

      _ ->
        comparison_required!()
    end
  end

  defp comparison_required! do
    Error.raise!(
      "intent",
      "lint",
      "the Intent needs a nonempty ## Source comparison of at most 8192 UTF-8 bytes; compare behaviors and settled non-secret literals with source/contract references, without raw originals or secrets",
      1
    )
  end

  def capture(root, slug, config, state) do
    publish(root, slug, %{
      "version" => 1,
      "request" => request(state["request"], state["source_path"]),
      "rounds" => Enum.map(state["rounds"], &resolved_round/1),
      "corrections" => [],
      "origin" => state["origin"],
      "contract_sha256" => Intent.hash(root, Intent.baseline(root, slug, config)),
      "comparison" => comparison(root, slug)
    })
  end

  defp resolved_round(round) do
    resolved =
      Map.new(round["answers"], fn {n, answer} ->
        question = Enum.at(round["questions"], String.to_integer(n) - 1)

        text =
          if Regex.match?(~r/^[a-z]$/, answer) do
            option = Enum.at(question["options"] || [], :binary.first(answer) - ?a)
            if option, do: option["label"], else: answer
          else
            answer
          end

        {n, text}
      end)

    Map.put(round, "resolved_answers", resolved)
  end

  def origin(root, config),
    do: %{
      "head" => Git.head(root),
      "tree" => Kogen.Snapshot.tree(root, Git.head(root), []),
      "configuration" => WorkingContext.hash(:erlang.term_to_binary(config))
    }

  def publish(root, slug, doc) do
    p = path(root, slug)
    File.mkdir_p!(Path.dirname(p))
    File.chmod!(Path.dirname(Path.dirname(p)), 0o700)
    File.chmod!(Path.dirname(p), 0o700)

    case File.read(p) do
      {:ok, old} ->
        archive = Path.join(Path.dirname(p), WorkingContext.hash(old) <> ".json")

        case File.lstat(archive) do
          {:error, :enoent} -> private_write(archive, old)
          _ -> validate_bound!(%{"path" => archive, "sha256" => WorkingContext.hash(old)})
        end

      {:error, :enoent} ->
        :ok

      _ ->
        refuse!(p)
    end

    private_write(p <> ".tmp", JSON.encode!(doc) <> "\n")
    File.rename!(p <> ".tmp", p)
  end

  defp private_write(path, bytes) do
    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      IO.binwrite(io, bytes)
      :file.sync(io)
    after
      File.close(io)
    end
  end

  def binding(root, slug, sha) do
    p = path(root, slug)

    case File.read(p) do
      {:error, :enoent} ->
        nil

      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"version" => 1, "contract_sha256" => ^sha}} ->
            ref = %{"path" => p, "sha256" => WorkingContext.hash(bytes), "contract_sha256" => sha}
            validate_bound!(ref)
            ref

          _ ->
            refuse!(p)
        end

      _ ->
        refuse!(p)
    end
  end

  def validate_bound!(nil), do: :ok

  def validate_bound!(ref) do
    parent = Path.dirname(ref["path"])
    ancestors = Enum.scan(1..3, parent, fn _, dir -> Path.dirname(dir) end)

    unless Enum.all?([parent | ancestors], fn dir ->
             match?({:ok, %{type: :directory}}, File.lstat(dir))
           end),
           do: refuse!(ref["path"])

    for dir <- [parent, Path.dirname(parent)] do
      case File.lstat(dir) do
        {:ok, %{type: :directory, mode: mode}} when Bitwise.band(mode, 0o777) == 0o700 -> :ok
        _ -> refuse!(ref["path"])
      end
    end

    case File.lstat(ref["path"]) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o777) == 0o600 ->
        case File.read(ref["path"]) do
          {:ok, bytes} ->
            unless WorkingContext.hash(bytes) == ref["sha256"], do: refuse!(ref["path"])

          _ ->
            refuse!(ref["path"])
        end

      _ ->
        refuse!(ref["path"])
    end

    :ok
  end

  defp refuse!(p),
    do:
      Error.raise!(
        "candidate",
        "source_provenance_changed",
        "source provenance custody missing, changed or unsafe: #{p}; inspect receipt and obtain fresh exact approval",
        1
      )

  def message(nil), do: "Source provenance: unavailable (legacy)"

  def message(ref),
    do:
      "Diagnostic source provenance (not authority): #{ref["path"]}\nManifest sha256: #{ref["sha256"]}; contract: #{ref["contract_sha256"]}. Retrieve full originals with read_file. Only the approved Intent authorizes implementation; omissions require ordinary Refine and new exact approval. Mapping is an aid, not proof."

  def card(nil), do: message(nil)

  def card(ref) do
    validate_bound!(ref)

    message(ref) <>
      "\nSource comparison:\n" <> JSON.decode!(File.read!(ref["path"]))["comparison"]
  end

  def refine(root, slug, correction, prior, source) do
    validate_bound!(source)
    p = path(root, slug)

    if source != nil do
      doc = JSON.decode!(File.read!(p))
      config = Config.load!(root)

      doc =
        doc
        |> Map.put(
          "corrections",
          doc["corrections"] ++ [Map.put(correction, "prior_contract_sha256", prior)]
        )
        |> Map.put("comparison", comparison(root, slug))
        |> Map.put("contract_sha256", Intent.hash(root, Intent.baseline(root, slug, config)))

      publish(root, slug, doc)
    end
  end
end
