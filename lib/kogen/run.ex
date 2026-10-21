defmodule Kogen.Run do
  @moduledoc """
  A Build's run record (LOOP-10): `.kogen/local/runs/<build-id>/log.jsonl` with requests and
  usage, tool calls and results, verification passes, reviews and the outcome; `result.json`;
  `review-<n>.json`. Credentials never appear in it.
  """
  defstruct [:id, :dir, :log]

  def start(root) do
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    dir = Path.join(root, ".kogen/local/runs/#{id}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    %__MODULE__{id: id, dir: dir, log: Path.join(dir, "log.jsonl")}
  end

  def log(nil, _event), do: :ok

  def log(%__MODULE__{log: path}, event) do
    line = event |> Map.put("at", DateTime.utc_now() |> DateTime.to_iso8601()) |> JSON.encode!()
    File.write!(path, line <> "\n", [:append])
  end

  def write(%__MODULE__{dir: dir}, name, data),
    do: File.write!(Path.join(dir, name), JSON.encode!(data) <> "\n")

  @doc "Publish a complete checkpoint by same-directory atomic rename."
  def checkpoint(run, data) do
    path = Path.join(run.dir, "checkpoint.json")
    tmp = path <> ".tmp"
    {:ok, io} = File.open(tmp, [:write, :binary])

    try do
      IO.binwrite(io, JSON.encode!(data) <> "\n")
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    File.rename!(tmp, path)
  end

  def decode_checkpoint(bytes) do
    for module <- Application.spec(:kogen, :modules) || [], do: Code.ensure_loaded(module)

    with {:ok, %{"version" => 2, "state" => state} = doc} <- JSON.decode(bytes),
         true <- is_binary(state),
         {:ok, binary} <- Base.decode64(state) do
      try do
        b = :erlang.binary_to_term(binary, [:safe])

        if valid_state?(b, doc) do
          {:ok, doc, b}
        else
          {:error, "malformed required checkpoint fields"}
        end
      rescue
        _ -> {:error, "damaged checkpoint state"}
      end
    else
      {:ok, %{"version" => version}} when version != 2 ->
        {:error, "incompatible checkpoint version #{inspect(version)}"}

      _ ->
        {:error, "malformed required checkpoint fields"}
    end
  end

  defp valid_state?(b, doc) do
    is_map(b) and
      Enum.all?(
        [:model, :phase, :t0, :last_pass, :last_review, :blocker, :parent, :root_run],
        &Map.has_key?(b, &1)
      ) and b.phase in [:startup, :building] and is_integer(b.t0) and
      Enum.all?(
        [:root, :slug, :start, :git_index, :start_tree, :approval_bytes],
        &is_binary(b[&1])
      ) and
      is_struct(b[:run], __MODULE__) and
      Enum.all?([b.run.id, b.run.dir, b.run.log], &is_binary/1) and
      is_struct(b[:config], Kogen.Config) and is_struct(b[:intent], Kogen.Intent) and
      b.intent.root == b.root and b.intent.slug == b.slug and
      is_binary(b.intent.title) and is_binary(b.intent.text) and
      b.model == Kogen.Intent.model(b.intent) and b.model != nil and
      valid_pass?(b.last_pass) and
      (b.last_pass == nil or not b.last_pass.green or
         complete_pass?(b.last_pass, b.config, b.intent, b.model)) and
      valid_review?(b.last_review) and
      valid_cache_states?(Map.get(b, :prompt_cache_states, %{})) and
      is_map(b[:baseline_digests]) and is_list(b[:baseline]) and
      Kogen.Config.path() in b.baseline and
      Enum.all?(b.baseline, &(is_binary(&1) and Map.has_key?(b.baseline_digests, &1))) and
      is_list(b[:excluded]) and Enum.all?(b.excluded, &is_binary/1) and
      Enum.all?(
        [:round, :pass, :review, :repairs, :model_active_ms, :unknown_requests],
        &(is_integer(b[&1]) and b[&1] >= 0)
      ) and
      Enum.all?([b[:usage], b[:attempt_usage]], fn usage ->
        is_map(usage) and
          Enum.all?(
            [:input, :output, :cached, :reasoning],
            &(is_integer(usage[&1]) and usage[&1] >= 0)
          )
      end) and valid_continuation?(b[:continuation]) and
      (not Map.has_key?(b.continuation, :pass) or not b.continuation.pass.green or
         complete_pass?(b.continuation.pass, b.config, b.intent, b.model)) and
      (b.continuation.stage != :landed or
         (is_map(b.last_pass) and is_map(b.last_review) and b.last_pass.green and
            b.last_review.verdict == "approve" and b.last_review[:tree] == b.last_pass.tree)) and
      Enum.all?(~w(identity candidate index approval), &is_binary(doc[&1])) and
      doc["approval"] == b.approval_bytes and
      match?({:ok, _}, Base.decode64(doc["index"])) and
      match?({:ok, _}, Base.decode64(doc["approval"]))
  end

  defp valid_cache_states?(states) when is_map(states) do
    Enum.all?(states, fn {key, state} ->
      is_binary(key) and is_map(state) and
        is_binary(state[:id]) and byte_size(state.id) in 1..256 and
        is_boolean(state[:unsupported]) and
        (is_nil(state[:response]) or
           (is_binary(state.response) and byte_size(state.response) in 1..256))
    end)
  end

  defp valid_cache_states?(_), do: false

  defp valid_input?(input), do: is_list(input) and Enum.all?(input, &is_map/1)

  defp valid_pass?(nil), do: true

  defp valid_pass?(pass) do
    is_map(pass) and pass[:clean] == true and is_integer(pass[:n]) and is_boolean(pass[:green]) and
      is_binary(pass[:tree]) and
      (pass[:acceptance] == :not_run or
         (is_map(pass[:acceptance]) and is_list(pass.acceptance[:scenarios]) and
            is_integer(pass.acceptance[:passed]) and is_integer(pass.acceptance[:status]) and
            is_list(pass.acceptance[:problems]))) and
      Map.has_key?(pass, :model) and is_list(pass[:checks]) and
      Enum.all?(pass.checks, fn check ->
        is_map(check) and is_binary(check[:name]) and is_binary(check[:command]) and
          is_integer(check[:status]) and is_binary(check[:output])
      end) and is_list(pass[:moved]) and is_list(pass[:failing]) and
      (not Map.has_key?(pass, :not_run) or
         (is_list(pass.not_run) and Enum.all?(pass.not_run, &is_binary/1)))
  end

  @doc false
  def complete_pass?(pass, config, intent, model) do
    with %{clean: true, green: true, moved: [], failing: [], acceptance: acceptance} <- pass,
         true <- Map.get(pass, :not_run, []) == [],
         %{status: 0, problems: [], scenarios: scenarios} <- acceptance,
         {:ok, expected} <-
           Kogen.Gherkin.parse(
             File.read!(Path.join(intent.root, Kogen.Intent.feature(intent.slug)))
           ) do
      # Old clean passes recorded setup failures in checks, but no successful setup list.
      Enum.map(scenarios, &{&1.line, &1.name, &1.status}) ==
        Enum.map(expected, &{&1.line, &1.name, "passed"}) and
        acceptance.passed == length(expected) and
        pass.model == if(model == :none, do: :none, else: {:ok, []}) and
        Enum.map(pass.checks, &{&1.name, &1.command, &1.status}) ==
          Enum.map(config.checks, fn {name, cmd} -> {name, cmd, 0} end) and
        ((not Map.has_key?(pass, :setup) and not Map.has_key?(pass, :not_run)) or
           Enum.map(pass.setup, &{&1.name, &1.command, &1.status}) ==
             Enum.with_index(config.setup, 1)
             |> Enum.map(fn {cmd, i} -> {"setup-#{i}", cmd, 0} end))
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_review?(nil), do: true

  defp valid_review?(review) do
    is_map(review) and review[:verdict] in ["approve", "changes", "pending", "invalid"] and
      is_list(review[:findings]) and is_integer(review[:n])
  end

  defp valid_continuation?(%{stage: :builder, input: input}), do: valid_input?(input)

  defp valid_continuation?(%{stage: :builder_verify, input: input, finish: finish}),
    do: valid_input?(input) and (is_nil(finish) or is_map(finish))

  defp valid_continuation?(%{stage: stage, pass: pass, session: session} = c)
       when stage in [:review, :review_verify, :review_retry_verify] do
    is_map(pass) and valid_pass?(pass) and
      is_map(session) and valid_input?(session[:input]) and is_list(session[:attempts]) and
      is_map(session[:role]) and is_binary(session.role[:model]) and
      is_binary(session.role[:effort]) and is_list(session[:tools]) and is_map(session[:usage]) and
      (stage == :review or
         (is_map(c[:verdict]) and valid_review?(Map.put(c.verdict, :n, 0)) and
            is_map(c[:usage]) and valid_input?(c[:input]) and is_binary(c[:tree])))
  end

  defp valid_continuation?(%{stage: :landed, commit: commit}), do: is_binary(commit)
  defp valid_continuation?(%{stage: stage}) when stage in [:startup, :tool, :commit], do: true
  defp valid_continuation?(_), do: false

  @mib 1_048_576
  @doc "Output as recorded: at most 1 MiB."
  def cap(text) when byte_size(text) <= @mib, do: text

  def cap(text) do
    marker = "\n[... cut in the run log ...]\n"
    size = div(@mib - byte_size(marker), 2)
    head = valid_prefix(binary_part(text, 0, size))
    tail = valid_suffix(binary_part(text, byte_size(text) - size, size))
    head <> marker <> tail
  end

  defp valid_prefix(text),
    do:
      if(String.valid?(text),
        do: text,
        else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
      )

  defp valid_suffix(text),
    do:
      if(String.valid?(text),
        do: text,
        else: valid_suffix(binary_part(text, 1, byte_size(text) - 1))
      )
end
