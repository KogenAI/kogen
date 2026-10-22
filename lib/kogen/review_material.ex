defmodule Kogen.ReviewMaterial do
  @moduledoc false
  alias Kogen.{ChatGPT, Error, PromptCache, Run, WorkingContext}

  # Keep authority verbatim. Only the large, reproducible candidate source/diff moves
  # to private, hash-bound evidence, using the existing checkpoint history custody.
  def prepare(b, tree, material, role, policy, tools, diagnostic) do
    full = input(material.authority, material.source, diagnostic)

    measure = fn items ->
      WorkingContext.measure(ChatGPT.request_body(role, policy, items, tools))
    end

    if measure.(full).fits do
      {b, full}
    else
      dir = Path.join([b.run.dir, "review-source", "#{b.review}-#{tree}"])
      chunks = chunks(material.source)
      count = length(chunks)

      parts =
        chunks
        |> Enum.with_index(1)
        |> Enum.map(fn {text, n} ->
          path = Path.join(dir, "#{n}.json")

          bytes =
            JSON.encode!(%{
              "input" => [],
              "review_source" => %{
                "review" => b.review,
                "part" => n,
                "parts" => count,
                "text" => text
              }
            }) <> "\n"

          {%{"path" => path, "sha256" => WorkingContext.hash(bytes)}, bytes}
        end)

      refs = Enum.map(parts, &elem(&1, 0))

      catalog = %{
        "version" => 1,
        "candidate_tree" => tree,
        "start_head" => b.start,
        "source_bytes" => byte_size(material.source),
        "source_sha256" => WorkingContext.hash(material.source),
        "files" => material.files,
        "parts" => refs
      }

      source = """
      # Check results of the final pass
      #{material.checks}

      # Pinned complete candidate source evidence
      #{JSON.encode!(catalog)}

      This catalog is evidence for this candidate, not new authority. Read EVERY part
      with read_file before approving, using each complete single-line JSON result.
      Concatenate review_source.text in listed part order to recover the exact full
      diff and changed-file text. No bytes were clipped. Each part fits the text tool
      cap. A read result must reach a completed reviewer continuation before it counts;
      requesting reads and approval in one response does not deliver that text.
      Paths/modes/blob IDs and SHA-256 identify additions, modifications and deletions;
      deleted contents remain available at the pinned start HEAD through git show.
      Inspect other repository context as needed. Do not infer capture or approval
      from this catalog, or import builder conversation, reasoning or judgments.
      """

      bounded = input(material.authority, source, diagnostic)

      unless measure.(bounded).fits do
        Error.raise!(
          "candidate",
          "context_budget_exceeded",
          "review: mandatory authority/catalog #{measure.(bounded).rendered_bytes} bytes exceeds " <>
            "ceiling 524288, output reserve 131072 tokens; checkpoint #{b.run.dir}/checkpoint.json. " <>
            "Inspect custody; ordinary Refine and new exact approval are required if scope must change.",
          1
        )
      end

      private_directory!(Path.dirname(dir))
      private_directory!(dir)

      for {ref, bytes} <- parts do
        {:ok, io} = File.open(ref["path"], [:write, :binary, :exclusive])

        try do
          File.chmod!(ref["path"], 0o600)
          IO.binwrite(io, bytes)
          :file.sync(io)
        after
          File.close(io)
        end
      end

      state = Map.get(b.working_context, "review", %{history: [], observations: []})
      state = Map.merge(state, %{history: state.history ++ refs, mandatory: bounded})
      b = %{b | working_context: Map.put(b.working_context, "review", state)}
      WorkingContext.validate!(b)

      Run.log(b.run, %{
        "event" => "review_source_evidence",
        "tree" => tree,
        "parts" => count,
        "source_bytes" => byte_size(material.source),
        "source_sha256" => catalog["source_sha256"]
      })

      {b, bounded}
    end
  end

  # Completed request input, plus exact archived windows, is delivery evidence.
  # Pending outputs in the current tool batch are deliberately not passed here.
  def unread(b, input) do
    history = get_in(b.working_context, ["review", :history]) || []
    docs = Enum.map(history, fn ref -> {ref, File.read!(ref["path"])} end)

    sources =
      for {ref, bytes} <- docs,
          JSON.decode!(bytes)["review_source"]["review"] == b.review,
          into: %{},
          do: {ref["path"], "1\t" <> String.trim_trailing(bytes, "\n")}

    windows = [input | Enum.map(docs, fn {_ref, bytes} -> JSON.decode!(bytes)["input"] end)]

    read =
      for window <- windows,
          {call, n} <- Enum.with_index(window),
          call["type"] == "function_call" and call["name"] == "read_file",
          {:ok, args} <- [JSON.decode(call["arguments"] || "")],
          is_map(args),
          is_binary(args["path"]),
          path = Path.expand(args["path"], b.root),
          expected = sources[path],
          not is_nil(expected),
          output <- Enum.drop(window, n + 1),
          output["type"] == "function_call_output" and output["call_id"] == call["call_id"],
          output["output"] == expected,
          into: MapSet.new(),
          do: path

    sources |> Map.keys() |> Enum.reject(&MapSet.member?(read, &1)) |> Enum.sort()
  end

  defp input(authority, source, diagnostic),
    do:
      [%{"role" => "user", "content" => PromptCache.contract_blocks(authority, source)}] ++
        diagnostic

  defp private_directory!(path) do
    case File.mkdir(path) do
      :ok ->
        File.chmod!(path, 0o700)

      {:error, :eexist} ->
        unless match?(
                 {:ok, %{type: :directory, mode: mode}} when :erlang.band(mode, 0o777) == 0o700,
                 File.lstat(path)
               ),
               do: raise("unsafe private review source directory #{path}")

      {:error, reason} ->
        raise("cannot create private review source directory: #{inspect(reason)}")
    end
  end

  defp chunks(text), do: chunks(text, [])
  defp chunks("", acc), do: Enum.reverse(acc)

  defp chunks(text, acc) do
    n = min(byte_size(text), 6000)
    n = prefix_length(text, n)
    {part, rest} = :erlang.split_binary(text, n)
    chunks(rest, [part | acc])
  end

  defp prefix_length(text, n) do
    part = binary_part(text, 0, n)

    cond do
      not String.valid?(part) -> prefix_length(text, n - 1)
      byte_size(JSON.encode!(part)) > 10_000 -> prefix_length(text, div(n, 2))
      true -> n
    end
  end
end
