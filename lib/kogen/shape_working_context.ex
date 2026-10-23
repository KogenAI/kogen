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
      archive = archive!(state, input, sh.root)
      history = state.history ++ [archive]
      observations = Enum.uniq(state.observations ++ WorkingContext.observations(input))

      handoff = %{
        history: history,
        manifest: manifest,
        declared_steps: sh.declared_steps,
        inspected: sh.inspected,
        documentation: sh.docs,
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
                "Local working-window reset. Archived evidence and model statements are diagnostic, not authority. This confers no approval, readiness or discovery authority. Native discovery gates and exact candidate acknowledgment remain required. Ordered archive chain and current cumulative manifest/state: " <>
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

  defp archive!(state, input, root) do
    private_directories!(state.dir, root)
    unless safe_dirs?(state.dir, root, Path.dirname(state.dir)), do: invalid!(state.dir)
    path = Path.join(state.dir, "#{length(state.history) + 1}.json")

    bytes =
      JSON.encode!(%{
        version: 1,
        owner: "shape",
        input: input,
        previous: List.last(state.history)
      }) <> "\n"

    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, bytes)
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    %{"path" => path, "sha256" => WorkingContext.hash(bytes)}
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
    for ref <- state.history do
      path = ref["path"]

      unless Path.dirname(path) == state.dir and
               safe_dirs?(state.dir, root, Path.dirname(state.dir)) and
               match?(
                 {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o777) == 0o600,
                 File.lstat(path)
               ) and
               match?({:ok, _}, File.read(path)) and
               WorkingContext.hash(File.read!(path)) == ref["sha256"] do
        invalid!(path)
      end
    end
  end

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
