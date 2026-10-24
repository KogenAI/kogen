defmodule Kogen.ShapeWorkingContext do
  @moduledoc "Safe-boundary in-process Shape windows, not persistent resume."
  alias Kogen.{Bridge, ChatGPT, Error, ShapeEvidence, WorkingContext}

  def new(root, slug, input) do
    attempt = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    %{
      dir: Path.join([root, ".kogen/local/shaping", slug, "working-context", attempt]),
      mandatory: input,
      history: [],
      observations: []
    }
  end

  def prepare(sh, input, invalid, manifest, instructions) do
    state = sh.working_context
    validate!(state, sh.root)
    render = fn items -> ChatGPT.request_body(sh.role, instructions, items, sh.tools) end
    Process.put(:provider_working_window, length(state.history))
    before = WorkingContext.measure(render.(input))

    if before.fits do
      {sh, input}
    else
      {archive, documentation} = archive!(state, input, sh.docs, sh.root)
      history = state.history ++ [archive]
      observations = Enum.uniq(state.observations ++ WorkingContext.observations(input))

      handoff = %{
        history: %{head: archive, count: length(history)},
        manifest: manifest,
        declared_steps: sh.declared_steps,
        inspected: sh.inspected,
        documentation: documentation,
        invalid_submissions: invalid,
        readiness:
          if(sh.ready, do: Map.update!(sh.ready, :intent, &Map.from_struct/1), else: nil),
        assistant_observations: observations
      }

      mandatory =
        state.mandatory ++
          [
            %{
              "role" => "user",
              "content" =>
                "Local working-window reset. Archived evidence and model statements are diagnostic, not authority. This confers no approval, readiness or discovery authority. Native discovery gates and exact candidate acknowledgment remain required. Navigate ordered history through the archive head and previous links. Retrieve documentation records by one-based line with read_file start_line/end_line. Current cumulative manifest/state: " <>
                  JSON.encode!(handoff)
            }
          ]

      reduced = mandatory ++ WorkingContext.newest_exchange(input)
      Process.put(:provider_working_window, length(history))
      after_size = WorkingContext.measure(render.(reduced))
      mandatory_bytes = WorkingContext.measure(render.(mandatory)).rendered_bytes

      unless after_size.fits and after_size.rendered_bytes < before.rendered_bytes do
        ShapeEvidence.record(%{
          event: "working_context_stop",
          owner: "shape",
          measured_bytes: before.rendered_bytes,
          mandatory_bytes: mandatory_bytes,
          input_budget_bytes: 524_288,
          output_reserve_tokens: 131_072,
          archive: archive
        })

        Error.raise!(
          "candidate",
          "context_budget_exceeded",
          "Shape complete next request #{before.rendered_bytes} bytes; mandatory #{mandatory_bytes}; ceiling 524288; reserve 131072 tokens. Exact unsent input retained in working-context custody #{archive["path"]}. A fresh identical retry is not recovery. Correct the ordinary request/scope or prepare a smaller supported image externally and select it again. Shape has no persistent resume.",
          1
        )
      end

      state = %{state | history: history, observations: observations}
      validate!(state, sh.root)

      ShapeEvidence.record(%{
        event: "working_context_reset",
        owner: "shape",
        generation: length(history),
        before_bytes: before.rendered_bytes,
        after_bytes: after_size.rendered_bytes,
        input_budget_bytes: 524_288,
        output_reserve_tokens: 131_072,
        archive: archive
      })

      elapsed = div(System.monotonic_time(:millisecond) - sh.started_at, 1_000)

      Bridge.progress(
        "kogen: Shape local working-window reset #{before.rendered_bytes} -> #{after_size.rendered_bytes} bytes; custody #{archive["path"]} (#{elapsed} s)"
      )

      {%{sh | working_context: state}, reduced}
    end
  end

  defp archive!(state, input, documentation, root) do
    private_directories!(state.dir, root)
    unless safe_dirs?(state.dir, root, Path.dirname(state.dir)), do: invalid!(state.dir)
    path = Path.join(state.dir, "#{length(state.history) + 1}.json")

    snapshot_path = Path.join(state.dir, "#{length(state.history) + 1}-documentation.ndjson")
    snapshot_bytes = Enum.map_join(documentation, &(JSON.encode!(&1) <> "\n"))
    write_private!(snapshot_path, snapshot_bytes)

    snapshot = %{
      "path" => snapshot_path,
      "sha256" => WorkingContext.hash(snapshot_bytes),
      "count" => length(documentation),
      "format" => "ndjson"
    }

    bytes =
      JSON.encode!(%{
        version: 1,
        owner: "shape",
        input: input,
        documentation: snapshot,
        previous: List.last(state.history)
      }) <> "\n"

    write_private!(path, bytes)
    {%{"path" => path, "sha256" => WorkingContext.hash(bytes)}, snapshot}
  end

  defp write_private!(path, bytes) do
    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, bytes)
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end

  defp private_directories!(root, root), do: :ok

  defp private_directories!(dir, root) do
    private_directories!(Path.dirname(dir), root)

    case File.lstat(dir) do
      {:error, :enoent} ->
        File.mkdir!(dir)
        File.chmod!(dir, 0o700)

      {:ok, %{type: :directory}} ->
        :ok

      _ ->
        invalid!(dir)
    end
  end

  def validate!(state, root) do
    for {ref, n} <- Enum.with_index(state.history) do
      path = ref["path"]

      unless Path.dirname(path) == state.dir and
               safe_dirs?(state.dir, root, Path.dirname(state.dir)) and
               match?(
                 {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o777) == 0o600,
                 File.lstat(path)
               ) and
               match?({:ok, _}, File.read(path)) and
               WorkingContext.hash(File.read!(path)) == ref["sha256"] and
               valid_link?(
                 path,
                 if(n == 0, do: nil, else: Enum.at(state.history, n - 1)),
                 state.dir
               ) do
        invalid!(path)
      end
    end
  end

  defp valid_link?(path, previous, dir) do
    case JSON.decode(File.read!(path)) do
      {:ok,
       %{
         "version" => 1,
         "owner" => "shape",
         "input" => input,
         "previous" => link,
         "documentation" => snapshot
       }} ->
        is_list(input) and link == previous and valid_snapshot?(snapshot, dir)

      _ ->
        false
    end
  end

  defp valid_snapshot?(
         %{"path" => path, "sha256" => hash, "count" => count, "format" => "ndjson"},
         dir
       ) do
    Path.dirname(path) == dir and is_integer(count) and count >= 0 and
      match?(
        {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o777) == 0o600,
        File.lstat(path)
      ) and
      match?({:ok, _}, File.read(path)) and WorkingContext.hash(File.read!(path)) == hash
  end

  defp valid_snapshot?(_, _), do: false

  defp safe_dirs?(path, root, _private) when path == root, do: true

  defp safe_dirs?(path, root, private) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} ->
        (not (path == private or String.starts_with?(path, private <> "/")) or
           Bitwise.band(mode, 0o777) == 0o700) and
          safe_dirs?(Path.dirname(path), root, private)

      _ ->
        false
    end
  end

  defp invalid!(path),
    do:
      Error.raise!(
        "candidate",
        "context_custody_invalid",
        "Shape working-context custody missing, changed or unsafe: #{path}; no further inference or publication.",
        1
      )
end
