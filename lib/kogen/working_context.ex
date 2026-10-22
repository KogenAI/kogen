defmodule Kogen.WorkingContext do
  @moduledoc "Private local working windows. Bytes are a conservative proxy, not provider usage."
  alias Kogen.{Bridge, Error, Snapshot}
  @budget 524_288
  @reserve 131_072

  def measure(body) do
    bytes = byte_size(JSON.encode!(body))

    %{
      rendered_bytes: bytes,
      input_budget_bytes: @budget,
      output_reserve_tokens: @reserve,
      fits: bytes <= @budget
    }
  end

  def hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  def validate!(b) do
    for {_owner, state} <- b.working_context, ref <- state.history do
      path = ref["path"]

      valid =
        Path.type(path) == :absolute and Path.expand(path) == path and
          String.starts_with?(path, b.root <> "/.kogen/local/runs/")

      unless valid and safe_directories?(Path.dirname(path), b.root <> "/.kogen/local/runs") and
               safe_file?(path) and match?({:ok, _}, File.read(path)) and
               hash(File.read!(path)) == ref["sha256"] do
        Error.raise!(
          "candidate",
          "resume_refused",
          "working-context history custody missing, changed or unsafe: #{path}; inspect checkpoint and archive before fresh approval",
          1
        )
      end
    end

    b
  end

  defp safe_directories?(path, stop) when path == stop do
    # runs/local/.kogen may predate this feature and need not be 0700, but
    # none may redirect otherwise intact private custody through a symlink.
    Enum.all?([path, Path.dirname(path), Path.dirname(Path.dirname(path))], fn dir ->
      match?({:ok, %{type: :directory}}, File.lstat(dir))
    end)
  end

  defp safe_directories?(path, stop) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} ->
        Bitwise.band(mode, 0o777) == 0o700 and safe_directories?(Path.dirname(path), stop)

      _ ->
        false
    end
  end

  defp safe_file?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o777) == 0o600
      _ -> false
    end
  end

  def prepare(b, owner, role, instructions, input, tools) do
    states = b.working_context

    state =
      Map.get(states, owner, %{
        history: [],
        mandatory: Enum.take_while(input, &(&1["role"] == "user")),
        observations: []
      })

    Process.put(:provider_working_window, length(state.history))
    body = fn items -> Kogen.ChatGPT.request_body(role, instructions, items, tools) end
    measured = measure(body.(input))

    if measured.fits do
      {Map.put(b, :working_context, Map.put(states, owner, state)), input}
    else
      observations = Enum.uniq(state.observations ++ observations(input))
      tree = Snapshot.tree(b.root, b.start, b.excluded)
      pass = b.last_pass

      status =
        cond do
          pass == nil -> "not_run"
          pass.tree != tree -> "stale"
          pass.green -> "green"
          true -> "failed"
        end

      path = Path.join([b.run.dir, "working-context", owner, "#{length(state.history) + 1}.json"])
      bytes = JSON.encode!(%{"input" => input}) <> "\n"
      history = state.history ++ [%{"path" => path, "sha256" => hash(bytes)}]

      reset = %{
        "version" => 1,
        "owner" => owner,
        "phase" => to_string(b.continuation.stage),
        "repair_owner" => owner,
        "repairs" => b.repairs,
        "candidate_tree" => tree,
        "approval_sha256" => JSON.decode!(Base.decode64!(b.approval_bytes))["sha256"],
        "checks" => %{
          "status" => status,
          "candidate_tree" => if(pass, do: pass.tree, else: nil),
          "failing" => if(pass, do: Map.get(pass, :failing, []), else: []),
          "not_run" => if(pass, do: Map.get(pass, :not_run, []), else: [])
        },
        "unfinished" => observations,
        "findings" => if(b.last_review, do: b.last_review.findings, else: []),
        "history" => history,
        "frozen_material" =>
          "Initial check evidence is historical. Only native results for the current candidate authorize eligibility.",
        "observation_authority" =>
          "Model observations are not approvals or proof; only native exact-candidate gates authorize completion."
      }

      message = %{
        "role" => "user",
        "content" => "Local working-window reset\n" <> JSON.encode!(reset)
      }

      mandatory = state.mandatory ++ [message]
      reduced = mandatory ++ newest_exchange(input)
      Process.put(:provider_working_window, length(history))
      next = measure(body.(reduced))
      mandatory_size = measure(body.(mandatory)).rendered_bytes

      unless next.fits and next.rendered_bytes < measured.rendered_bytes do
        Error.raise!(
          "candidate",
          "context_budget_exceeded",
          "#{owner}: measured #{measured.rendered_bytes} bytes; mandatory #{mandatory_size} bytes; ceiling #{@budget}, output reserve #{@reserve} tokens. Retained checkpoint #{b.run.dir}/checkpoint.json and history #{Enum.map_join(state.history, ", ", & &1["path"])}. Inspect custody; prepare a smaller supported image externally or use ordinary Refine and new exact approval if scope must change.",
          1
        )
      end

      dir = Path.dirname(path)
      File.mkdir_p!(dir)
      File.chmod!(Path.dirname(dir), 0o700)
      File.chmod!(dir, 0o700)
      {:ok, io} = File.open(path, [:write, :binary, :exclusive])

      try do
        File.chmod!(path, 0o600)
        IO.binwrite(io, bytes)
        :file.sync(io)
      after
        File.close(io)
      end

      state = %{state | history: history, observations: observations}

      Bridge.progress(
        "kogen: #{owner} local reset #{measured.rendered_bytes} -> #{next.rendered_bytes} bytes; ceiling #{@budget}; reserve #{@reserve}; history #{path}"
      )

      {Map.put(b, :working_context, Map.put(states, owner, state)), reduced}
    end
  end

  defp observations(input) do
    Enum.flat_map(input, fn
      %{"role" => "assistant", "content" => _} = item ->
        [Map.take(item, ~w(id phase content))]

      %{"type" => "function_call", "name" => "finish", "arguments" => args} ->
        case JSON.decode(args) do
          {:ok, %{"summary" => summary}} -> [summary]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp newest_exchange(input) do
    # Completed output batches delimit exchanges; never split a parallel call batch.
    boundaries =
      input
      |> Enum.with_index()
      |> Enum.filter(fn {item, i} ->
        item["type"] == "function_call_output" and
          (Enum.at(input, i + 1) || %{})["type"] != "function_call_output"
      end)

    previous =
      case Enum.reverse(boundaries) do
        [{_, _last}, {_, previous} | _] -> previous
        _ -> -1
      end

    Enum.drop(input, previous + 1)
    |> Enum.drop_while(fn item ->
      item["type"] not in ["reasoning", "message", "function_call"]
    end)
  end
end
