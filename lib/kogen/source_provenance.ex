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

  def binding(root, slug) do
    p = path(root, slug)

    case File.read(p) do
      {:error, :enoent} ->
        case File.lstat(Path.dirname(p)) do
          {:error, :enoent} -> nil
          _ -> refuse!(p)
        end

      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"version" => 1, "contract_sha256" => contract}} when is_binary(contract) ->
            ref = %{
              "path" => p,
              "sha256" => WorkingContext.hash(bytes),
              "contract_sha256" => contract
            }

            validate_bound!(ref)
            ref

          _ ->
            refuse!(p)
        end

      _ ->
        refuse!(p)
    end
  end

  # A stale marker's displaced pointer is resolved only by its pinned digest in
  # native history. Matching authority must still have its exact current receipt.
  def resolve_approval!(root, slug, approval) do
    case approval && approval["source_provenance"] do
      nil ->
        nil

      ref ->
        current = path(root, slug)

        unless ref["path"] == current and is_binary(ref["sha256"]) and
                 Regex.match?(~r/\A[0-9a-f]{64}\z/, ref["sha256"]),
               do: refuse!(current)

        sha = Intent.hash(root, Intent.baseline(root, slug, Config.load!(root)))
        if approval["sha256"] == sha, do: validate_bound!(ref)

        resolved =
          case File.read(current) do
            {:ok, bytes} ->
              if WorkingContext.hash(bytes) == ref["sha256"],
                do: ref,
                else:
                  Map.put(ref, "path", Path.join(Path.dirname(current), ref["sha256"] <> ".json"))

            _ ->
              Map.put(ref, "path", Path.join(Path.dirname(current), ref["sha256"] <> ".json"))
          end

        validate_bound!(resolved)
        if binding(root, slug) == nil, do: refuse!(current)
        resolved
    end
  end

  def refresh(root, slug, sha, source) do
    validate_bound!(source)
    unless binding(root, slug) == source, do: refuse!(path(root, slug))

    if source && source["contract_sha256"] != sha do
      doc = JSON.decode!(File.read!(source["path"]))
      publish(root, slug, transition(doc, source, sha))
    end

    binding(root, slug)
  end

  defp transition(doc, source, sha) do
    doc
    |> Map.put(
      "previous_receipt",
      Map.put(
        source,
        "path",
        Path.join(Path.dirname(source["path"]), source["sha256"] <> ".json")
      )
    )
    |> Map.put("prior_contract_sha256", source["contract_sha256"])
    |> Map.put("contract_sha256", sha)
  end

  # Roll back only bytes published by this operation, never concurrent edits.
  def restore(nil, _previous), do: :ok

  def restore(published, previous) do
    intact =
      try do
        validate_bound!(published)
        true
      rescue
        Kogen.Error -> false
      end

    if intact, do: File.write!(published["path"], previous)
  end

  def validate_bound!(nil), do: :ok

  def validate_bound!(ref) do
    parent = Path.dirname(ref["path"])
    ancestors = Enum.scan(1..3, parent, fn _, dir -> Path.dirname(dir) end)

    unless Enum.all?([parent | ancestors], fn dir ->
             match?({:ok, %{type: :directory}}, File.lstat(dir))
           end),
           do: refuse!("#{ref["path"]} (expected SHA-256 #{ref["sha256"]})")

    for dir <- [parent, Path.dirname(parent)] do
      case File.lstat(dir) do
        {:ok, %{type: :directory, mode: mode}} when Bitwise.band(mode, 0o777) == 0o700 -> :ok
        _ -> refuse!("#{ref["path"]} (expected SHA-256 #{ref["sha256"]})")
      end
    end

    case File.lstat(ref["path"]) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o777) == 0o600 ->
        case File.read(ref["path"]) do
          {:ok, bytes} ->
            unless WorkingContext.hash(bytes) == ref["sha256"],
              do: refuse!("#{ref["path"]} (expected SHA-256 #{ref["sha256"]})")

          _ ->
            refuse!("#{ref["path"]} (expected SHA-256 #{ref["sha256"]})")
        end

      _ ->
        refuse!("#{ref["path"]} (expected SHA-256 #{ref["sha256"]})")
    end

    :ok
  end

  defp refuse!(p),
    do:
      Error.raise!(
        "candidate",
        "source_provenance_changed",
        "source provenance custody missing, changed or unsafe: #{p}; restore the named exact custody from preserved native receipt history, then run the card; if unavailable, stop",
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
        |> transition(source, Intent.hash(root, Intent.baseline(root, slug, config)))

      validate_bound!(source)
      unless binding(root, slug) == source, do: refuse!(p)
      publish(root, slug, doc)
      binding(root, slug)
    end
  end
end
