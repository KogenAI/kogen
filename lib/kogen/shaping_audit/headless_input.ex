defmodule Kogen.ShapingAudit.HeadlessInput do
  @moduledoc """
  Exact recording checks and Stop-time admission for headless Shaping.

  The audit owns this small boundary because it consumes the immutable input
  journal, while the Shaping engine uses the exported API to decide which
  accepted messages have been recorded.
  """

  alias Kogen.ShapingAudit.{Package, Questions}

  @session_root ".kogen/runtime/shaping"
  @frame_pattern ~r/```kogen-recorded-input-v1\s+(\{.*?\})\s+```/s
  @input_token ~r/\[input (in-\d{4}-[0-9a-f]{8})\]/
  @intent_id ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @doc "Returns exact-valid input IDs and their answer-entry counts."
  def recorded(questions_text, inputs) when is_list(inputs) do
    entries = Questions.entries(Questions.parse(questions_text), "Shaper answers")
    token_counts = token_counts(questions_text)

    Enum.reduce(inputs, %{}, fn input, acc ->
      id = input["id"]
      bytes = input["text"]

      if recorded_once?(entries, token_counts, id, bytes), do: Map.put(acc, id, 1), else: acc
    end)
  end

  defp recorded_once?(entries, token_counts, id, bytes)
       when is_binary(id) and is_binary(bytes) do
    Map.get(token_counts, id, 0) == 1 and
      Enum.count(entries, &exact_entry?(&1.text, id, bytes)) == 1
  end

  defp recorded_once?(_entries, _token_counts, _id, _bytes), do: false

  @doc "Builds the canonical visible token and reversible exact-input frame."
  def frame(id, bytes) when is_binary(id) and is_binary(bytes) do
    Jason.encode!(%{
      "schema" => "kogen.recorded-input/v1",
      "input_id" => id,
      "byte_length" => byte_size(bytes),
      "sha256" => sha256(bytes),
      "verbatim_text" => bytes,
      "bytes_base64" => Base.encode64(bytes)
    })
    |> then(&"[input #{id}]\n  ```kogen-recorded-input-v1\n  #{&1}\n  ```")
  end

  @doc "Whether one Shaper-answer entry carries `id` and the exact input bytes."
  def exact_entry?(entry_text, id, bytes)
      when is_binary(entry_text) and is_binary(id) and is_binary(bytes) do
    id in tokens(entry_text) and
      case Regex.scan(@frame_pattern, entry_text) do
        [[_whole, json]] -> valid_frame?(json, id, bytes)
        _ -> false
      end
  end

  def exact_entry?(_entry_text, _id, _bytes), do: false

  @doc "Counts the entries carrying each input token, including invalid frames."
  def token_counts(questions_text) do
    questions_text
    |> Questions.parse()
    |> Questions.entries("Shaper answers")
    |> Enum.map(&(tokens(&1.text) |> Enum.uniq()))
    |> List.flatten()
    |> Enum.frequencies()
  end

  @doc "Synchronously binds a newly discovered Draft to its immutable session brief."
  def admit_brief(root, intent_id, package),
    do: admit_brief(root, intent_id, package, session_dir_for(root, intent_id))

  @doc "Admits only the active session directory bound to this checkout and intent."
  def admit_brief(
        root,
        intent_id,
        %{slug: slug, package_rel: package_rel} = package,
        active_session_dir
      )
      when is_binary(intent_id) and is_binary(slug) and is_binary(package_rel) and
             is_binary(active_session_dir) do
    with true <- Regex.match?(@intent_id, intent_id),
         true <- Path.expand(active_session_dir) == Path.expand(session_dir_for(root, intent_id)),
         {:ok, session} <- read_session(root, intent_id),
         true <- session["intent_id"] == intent_id,
         false <- slug in List.wrap(session["preexisting_slugs"]),
         :drafts <- package.location,
         {:ok, found} <- Package.find_by_id(root, intent_id),
         true <- found.slug == slug and found.package_rel == package_rel,
         true <- safe_package_directory?(root, package_rel),
         {:ok, bytes, input_id} <- accepted_brief(root, intent_id),
         :ok <- install_immutable_brief(root, package_rel, bytes),
         {:ok, %{files: files}} <- Package.load(root, package_rel),
         ^bytes <- Map.get(files, "evidence/brief.md") do
      {:ok, %{input_id: input_id}}
    else
      false -> {:error, :session_package_or_collision_mismatch}
      nil -> {:error, :session_or_original_brief_missing}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :session_package_or_original_brief_mismatch}
    end
  rescue
    _error -> {:error, :brief_admission_failed}
  end

  def admit_brief(_root, _intent_id, _package, _active_session_dir),
    do: {:error, :invalid_package_binding}

  defp session_dir_for(root, intent_id),
    do: Path.join([root, @session_root, to_string(intent_id)])

  defp safe_package_directory?(root, package_rel) do
    package_rel
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1)))
  end

  defp valid_frame?(json, id, bytes) do
    digest = sha256(bytes)

    with {:ok,
          %{
            "schema" => "kogen.recorded-input/v1",
            "input_id" => ^id,
            "byte_length" => length,
            "sha256" => ^digest,
            "verbatim_text" => ^bytes,
            "bytes_base64" => encoded
          }} <- Jason.decode(json),
         true <- is_integer(length) and length == byte_size(bytes),
         {:ok, decoded} <- Base.decode64(encoded),
         true <- decoded == bytes do
      true
    else
      _ -> false
    end
  end

  defp tokens(text) do
    text
    |> strip_recording_frames()
    |> then(&Regex.scan(@input_token, &1))
    |> Enum.map(fn [_, id] -> id end)
  end

  defp strip_recording_frames(text), do: Regex.replace(@frame_pattern, text, "")

  defp read_session(root, intent_id) do
    path = Path.join([root, @session_root, intent_id, "session.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"schema" => 1} = session} <- Jason.decode(bytes) do
      {:ok, session}
    else
      _ -> {:error, :session_missing_or_invalid}
    end
  end

  defp accepted_brief(root, intent_id) do
    dir = Path.join([root, @session_root, intent_id])

    with {:ok, names} <- File.ls(Path.join(dir, "inputs")),
         records <- Enum.filter(names, &Regex.match?(~r/^\d{4}\.json$/, &1)),
         {:ok, briefs} <- read_brief_records(dir, records),
         [%{bytes: bytes, id: id}] <- briefs do
      {:ok, bytes, id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :accepted_brief_missing_or_invalid}
    end
  end

  defp read_brief_records(dir, records) do
    inputs = Path.join(dir, "inputs")

    Enum.reduce_while(records, {:ok, []}, fn name, {:ok, briefs} = result ->
      case read_brief_record(inputs, name) do
        :not_brief -> {:cont, result}
        {:ok, brief} -> {:cont, {:ok, [brief | briefs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_brief_record(inputs, name) do
    number = String.slice(name, 0, 4)

    with {:ok, meta_bytes} <- File.read(Path.join(inputs, name)),
         {:ok, meta} <- Jason.decode(meta_bytes) do
      if meta["kind"] == "brief",
        do: validate_brief_record(inputs, number, meta),
        else: :not_brief
    else
      _ -> {:error, :accepted_brief_invalid}
    end
  end

  defp validate_brief_record(inputs, number, meta) do
    with {:ok, bytes} <- File.read(Path.join(inputs, number <> ".md")),
         id = input_id(number, bytes),
         true <- meta["number"] == String.to_integer(number),
         true <- meta["id"] == id,
         true <- meta["sha256"] == sha256(bytes) do
      {:ok, %{bytes: bytes, id: id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :accepted_brief_invalid}
    end
  end

  defp install_immutable_brief(root, package_rel, bytes) do
    evidence = Path.join([root, package_rel, "evidence"])
    target = Path.join(evidence, "brief.md")

    case File.read(target) do
      {:ok, ^bytes} -> :ok
      {:ok, _other} -> {:error, :immutable_brief_conflict}
      {:error, :enoent} -> create_brief(evidence, target, bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_brief(evidence, target, bytes) do
    case File.lstat(evidence) do
      {:ok, %File.Stat{type: :directory}} ->
        write_new(target, bytes)

      {:error, :enoent} ->
        case File.mkdir(evidence) do
          :ok -> write_new(target, bytes)
          {:error, :eexist} -> create_brief(evidence, target, bytes)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :evidence_directory_invalid}
    end
  end

  defp write_new(target, bytes) do
    temporary = target <> ".admission-#{System.pid()}-#{System.unique_integer([:positive])}"

    case File.open(temporary, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = IO.binwrite(io, bytes)
        result = if result == :ok, do: :file.sync(io), else: result
        File.close(io)

        if result == :ok do
          link_new_brief(temporary, target, bytes)
        else
          File.rm(temporary)
          result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_new_brief(temporary, target, bytes) do
    result = File.ln(temporary, target)
    File.rm(temporary)

    case result do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.read(target) do
          {:ok, ^bytes} -> :ok
          {:ok, _other} -> {:error, :immutable_brief_conflict}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp input_id(number, bytes) do
    "in-#{number}-#{sha256(bytes) |> binary_part(0, 8)}"
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
