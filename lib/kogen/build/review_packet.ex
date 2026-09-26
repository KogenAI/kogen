defmodule Kogen.Build.ReviewPacket do
  @moduledoc """
  The bounded, Candidate-bound evidence a fresh Reviewer starts from.

  Before each Review the controller writes one immutable packet per attempt
  next to the tracking record. It is canonical JSON (keys sorted) and never
  larger than #{65_536} bytes. Long string fields are cut at a UTF-8 boundary
  with a per-field cap; a cut or left-out value is replaced by a stub carrying
  the SHA-256 and byte count of the full source and a JSON pointer into the
  record, and is listed in `omitted`. Serialized JSON is never byte-sliced.
  The scenario, risk and open finding ids are always present, and so is one
  complete index entry per verification-surface ledger item (its full diff
  stays a retained file cited by locator and sha256, never inlined): if they
  alone cannot fit, building fails instead of dropping them.

  Digests of structured values are over their canonical JSON encoding; digests
  of strings are over the string's bytes.
  """

  @limit 65_536
  @schema_version 1
  @directory "review-packets"

  @keys ~w(schema_version build_id attempt_number attempt_token candidate_id scenario_ids
           risk_ids handoff developer_notes receipts open_findings superseded_objection
           verification_ledger base_suite omitted record)

  # Tried in order until the whole packet fits. The first profile holds the
  # per-field caps; later profiles only tighten them, and the last one keeps
  # nothing beyond the required ids and digest-bound stubs.
  @profiles [
    %{notes: 16_384, output: 2_048, handoff: 24_576, finding: 8_192},
    %{notes: 8_192, output: 1_024, handoff: 12_288, finding: 2_048},
    %{notes: 2_048, output: 256, handoff: 2_048, finding: 256},
    %{notes: 0, output: 0, handoff: 0, finding: 0}
  ]

  @inner_caps [4_096, 1_024, 256, 64]

  @superseded_label "advisory: a contract objection Jev read in the Developer's notes was written before controller verification of this same attempt passed; it did not stop the Build and is not a finding. Judge every scenario yourself."

  @record_use "audit locator only: start from this packet and never dump the whole record; open a record section only through a locator named here"

  @doc "The packet byte bound."
  def limit, do: @limit

  @doc "The exact top-level packet keys."
  def keys, do: @keys

  @doc """
  Builds canonical packet bytes. `input` holds `:record` (the current tracking
  record map), `:record_path`, `:record_bytes`, `:candidate_id` and
  `:open_findings` (the open finding ids). The packet is bound to the
  record's latest attempt, whose `verification_ledger` and `base_suite` it
  carries when present.
  """
  @spec build(map()) :: {:ok, binary()} | {:error, String.t()}
  def build(input) do
    record = input.record
    index = length(record["attempts"]) - 1
    attempt = List.last(record["attempts"])

    result =
      Enum.find_value(@profiles, fn profile ->
        bytes = input |> packet(record, index, attempt, profile) |> encode()
        if byte_size(bytes) <= @limit, do: bytes
      end)

    case result do
      nil ->
        {:error,
         "review packet integrity failure: the required scenario, risk and open finding ids alone exceed #{@limit} bytes"}

      bytes ->
        {:ok, bytes}
    end
  end

  @doc """
  Writes packet bytes once, with exclusive create, at
  `<record dir>/review-packets/<attempt-number>.json` and returns the binding
  the controller keeps in its state and in the attempt.
  """
  @spec write(Path.t(), non_neg_integer(), binary(), String.t(), String.t(), Path.t()) ::
          {:ok, map()} | {:error, String.t()}
  def write(record_path, number, bytes, token, candidate_id, root \\ File.cwd!()) do
    directory = Path.join(Path.dirname(record_path), @directory)
    path = Path.join(directory, "#{number}.json")

    with :ok <- owned_directory(directory),
         :ok <- exclusive_write(path, bytes) do
      {:ok,
       %{
         "path" => Path.relative_to(Path.expand(path), Path.expand(root)),
         "sha256" => sha256(bytes),
         "byte_count" => byte_size(bytes),
         "attempt_token" => token,
         "candidate_id" => candidate_id
       }}
    end
  end

  @doc """
  Confirms that a written packet still has exactly its bound bytes. Its
  control-relative `path` resolves against `root`, the control checkout.
  """
  @spec verify(map(), Path.t()) :: :ok | {:error, String.t()}
  def verify(binding, root \\ ".")

  def verify(%{"path" => path, "sha256" => digest, "byte_count" => count}, root)
      when is_binary(path) do
    case File.read(Path.expand(path, root)) do
      {:ok, bytes} ->
        if byte_size(bytes) == count and sha256(bytes) == digest,
          do: :ok,
          else: {:error, "review packet mutated: #{path}"}

      {:error, _reason} ->
        {:error, "review packet missing: #{path}"}
    end
  end

  def verify(_binding, _root), do: {:error, "review packet binding is malformed"}

  @doc """
  Returns the superseded-objection record, or `nil` when `objections` must
  still stop the Build. A confident objection is superseded only when it is
  stale in this exact attempt: the settled verification passed, every cycle
  belongs to the same verification history (`binding`'s attempt token and
  Developer session), an earlier cycle failed, and the final cycle passed on
  the settled Candidate. It then stays in the record and reaches the fresh
  Reviewer as a labelled advisory item.
  """
  @spec superseded_objection(map(), map(), [map()], number()) :: map() | nil
  def superseded_objection(_verification, _binding, [], _threshold), do: nil

  def superseded_objection(verification, binding, objections, threshold) do
    cycles = verification["cycles"] || []
    final = List.last(cycles) || %{}

    failed =
      for cycle <- Enum.drop(cycles, -1), cycle["status"] == "failed", do: cycle["sequence"]

    if verification["terminal_state"] == "passed" and same_history?(cycles, binding) and
         failed != [] and final_pass?(final, binding) do
      %{
        "items" => objections,
        "confidences" => Map.new(objections, &{"#{&1["kind"]}:#{&1["id"]}", &1["confidence"]}),
        "threshold" => threshold,
        "failed_cycle_sequences" => failed,
        "passing_cycle_sequence" => final["sequence"],
        "attempt_token" => binding.attempt_token,
        "developer_session_id" => binding.developer_session_id,
        "candidate_id" => binding.candidate_id
      }
    end
  end

  defp same_history?(cycles, binding) do
    Enum.all?(
      cycles,
      &(&1["attempt_token"] == binding.attempt_token and
          &1["developer_session_id"] == binding.developer_session_id)
    )
  end

  defp final_pass?(final, binding),
    do: final["status"] == "passed" and final["candidate_id"] == binding.candidate_id

  @doc "Canonical JSON: Jason with every object's keys sorted."
  @spec encode(term()) :: binary()
  def encode(value), do: value |> ordered() |> Jason.encode!()

  defp packet(input, record, index, attempt, profile) do
    base = "/attempts/#{index}"

    {handoff, handoff_omitted} =
      fit(attempt["handoff"], base <> "/handoff", "/handoff", profile.handoff, :head)

    {notes, notes_omitted} = notes(attempt, base, profile.notes)
    {receipts, receipt_omitted} = receipts(attempt, base, profile.output)
    {findings, finding_omitted} = findings(record, input.open_findings, profile.finding)

    %{
      "schema_version" => @schema_version,
      "build_id" => input.record_path |> Path.dirname() |> Path.basename(),
      "attempt_number" => attempt["number"],
      "attempt_token" => attempt["attempt_token"],
      "candidate_id" => input.candidate_id,
      "scenario_ids" => Enum.map(record["scenarios"], & &1["id"]),
      "risk_ids" => Enum.map(record["risks"], & &1["id"]),
      "handoff" => handoff,
      "developer_notes" => notes,
      "receipts" => receipts,
      "open_findings" => findings,
      "superseded_objection" => superseded(attempt["superseded_objection"]),
      "verification_ledger" => ledger_index(attempt["verification_ledger"], base),
      "base_suite" => attempt["base_suite"],
      "omitted" =>
        handoff_omitted ++
          notes_omitted ++ receipt_omitted ++ finding_omitted ++ left_out(record, index),
      "record" => %{
        "path" => input.record_path,
        "byte_count" => byte_size(input.record_bytes),
        "use" => @record_use
      }
    }
  end

  defp notes(attempt, base, cap) do
    case attempt["developer_notes"] do
      %{"text" => text} when is_binary(text) ->
        fit(text, base <> "/developer_notes/text", "/developer_notes", cap, :head)

      %{} = notes ->
        # Notes that are not valid UTF-8 exist only as exact base64 bytes.
        locator = base <> "/developer_notes/content_base64"

        stub = %{
          "text" => "",
          "truncated" => true,
          "sha256" => notes["sha256"],
          "byte_count" => notes["byte_count"],
          "locator" => locator
        }

        {stub, [omission("/developer_notes", locator, notes["sha256"], notes["byte_count"])]}

      nil ->
        {nil, []}
    end
  end

  # Controller receipts are one uniform list; records written before it keep
  # their separate `check` and `targets` fields.
  defp receipt_sources(%{"receipts" => receipts}, base) when is_list(receipts) do
    receipts
    |> Enum.with_index()
    |> Enum.map(fn {receipt, j} -> {receipt, "#{base}/receipts/#{j}"} end)
  end

  defp receipt_sources(attempt, base) do
    check = if attempt["check"], do: [{attempt["check"], base <> "/check"}], else: []

    targets =
      attempt
      |> Map.get("targets", [])
      |> Enum.with_index()
      |> Enum.map(fn {receipt, j} -> {receipt, "#{base}/targets/#{j}"} end)

    check ++ targets
  end

  # One complete index entry per ledger item with the locator and digest of
  # its retained full diff; diffs are never inlined.
  defp ledger_index(nil, _base), do: nil

  defp ledger_index(ledger, base) do
    %{
      "base_commit" => ledger["base_commit"],
      "catalog" => ledger["catalog"],
      "receipts_with_changed_runner" => ledger["receipts_with_changed_runner"],
      "locator" => base <> "/verification_ledger",
      "disposition_required" =>
        "return exactly one `ledger` entry per item: `justified: <scenario-id or finding-id>` or `weakening`",
      "items" =>
        Enum.map(ledger["items"], fn item ->
          Map.take(
            item,
            ~w(path status old_path runner_class preservation_selector diff_stat base_blob
               candidate_blob diff)
          )
        end)
    }
  end

  defp receipts(attempt, base, cap) do
    attempt
    |> receipt_sources(base)
    |> Enum.with_index()
    |> Enum.map(fn {{receipt, locator}, k} ->
      output = receipt["output"] || ""
      {tail, omitted} = fit(output, locator <> "/output", "/receipts/#{k}/output", cap, :tail)

      summary =
        receipt
        |> Map.take(
          ~w(target status exit_code candidate_id attempt_token session_id developer_session_id
             cycle_sequence finished_at log_path log_sha256 cleanup reused_from)
        )
        |> Map.merge(%{
          "output_sha256" => sha256(output),
          "output_byte_count" => byte_size(output),
          "output" => tail,
          "locator" => locator
        })

      {summary, omitted}
    end)
    |> Enum.unzip()
    |> then(fn {summaries, omitted} -> {summaries, List.flatten(omitted)} end)
  end

  defp findings(record, open_ids, cap) do
    record["findings"]
    |> Enum.with_index()
    |> Enum.filter(fn {finding, _k} -> finding["id"] in open_ids end)
    |> Enum.map(fn {finding, k} ->
      body = Map.take(finding, ~w(scenario_ids status origin disposition_history))

      {fitted, omitted} =
        fit(body, "/findings/#{k}", "/open_findings/#{finding["id"]}", cap, :head)

      {Map.put(fitted, "id", finding["id"]), omitted}
    end)
    |> Enum.unzip()
    |> then(fn {findings, omitted} -> {findings, List.flatten(omitted)} end)
  end

  defp superseded(nil), do: nil
  defp superseded(objection), do: Map.put(objection, "label", @superseded_label)

  # Record sections the packet never carries, bound by digest and locator.
  defp left_out(record, index) do
    attempt = Enum.at(record["attempts"], index)

    prior =
      for k <- 0..(index - 1)//1 do
        {"/attempts/#{k}", Enum.at(record["attempts"], k)}
      end

    current =
      for key <- ~w(verification jev), Map.has_key?(attempt, key) do
        {"/attempts/#{index}/#{key}", attempt[key]}
      end

    Enum.map(prior ++ current, fn {locator, value} ->
      encoded = encode(value)
      Map.put(omission(nil, locator, sha256(encoded), byte_size(encoded)), "kind", "left_out")
    end)
  end

  defp fit(value, locator, field, budget, direction) when is_binary(value) do
    if byte_size(value) <= budget do
      {value, []}
    else
      text = cut(value, budget, direction)

      stub = %{
        "text" => text,
        "truncated" => true,
        "sha256" => sha256(value),
        "byte_count" => byte_size(value),
        "locator" => locator
      }

      {stub, [omission(field, locator, stub["sha256"], stub["byte_count"])]}
    end
  end

  defp fit(value, locator, field, budget, _direction) when is_map(value) or is_list(value) do
    encoded = encode(value)

    if byte_size(encoded) <= budget do
      {value, []}
    else
      fitted =
        @inner_caps
        |> Enum.filter(&(&1 < budget))
        |> Enum.find_value(&cut_within(value, locator, field, &1, budget))

      fitted || omit(encoded, locator, field)
    end
  end

  defp fit(value, _locator, _field, _budget, _direction), do: {value, []}

  defp cut_within(value, locator, field, cap, budget) do
    {cut_value, omitted} = cut_strings(value, locator, field, cap)
    if byte_size(encode(cut_value)) <= budget, do: {cut_value, omitted}
  end

  defp omit(encoded, locator, field) do
    stub = %{
      "omitted" => true,
      "sha256" => sha256(encoded),
      "byte_count" => byte_size(encoded),
      "locator" => locator
    }

    {stub, [omission(field, locator, stub["sha256"], stub["byte_count"])]}
  end

  defp cut_strings(value, locator, field, cap) when is_binary(value),
    do: fit(value, locator, field, cap, :head)

  defp cut_strings(value, locator, field, cap) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.map_reduce([], fn {key, item}, acc ->
      token = pointer_token(key)
      {fitted, omitted} = cut_strings(item, locator <> "/" <> token, field <> "/" <> token, cap)
      {{key, fitted}, acc ++ omitted}
    end)
    |> then(fn {pairs, omitted} -> {Map.new(pairs), omitted} end)
  end

  defp cut_strings(value, locator, field, cap) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {item, i}, acc ->
      {fitted, omitted} = cut_strings(item, "#{locator}/#{i}", "#{field}/#{i}", cap)
      {fitted, acc ++ omitted}
    end)
  end

  defp cut_strings(value, _locator, _field, _cap), do: {value, []}

  defp omission(field, locator, digest, count) do
    %{
      "kind" => "truncated",
      "field" => field,
      "locator" => locator,
      "sha256" => digest,
      "byte_count" => count
    }
  end

  defp cut(value, budget, :head), do: utf8_prefix(binary_part(value, 0, budget))

  defp cut(value, budget, :tail),
    do: utf8_suffix(binary_part(value, byte_size(value) - budget, budget))

  # Drops at most one partial code point at the cut edge.
  defp utf8_prefix(bytes, drop \\ 0) do
    cond do
      String.valid?(bytes) ->
        bytes

      drop < 3 and bytes != "" ->
        utf8_prefix(binary_part(bytes, 0, byte_size(bytes) - 1), drop + 1)

      true ->
        ""
    end
  end

  defp utf8_suffix(bytes, drop \\ 0) do
    cond do
      String.valid?(bytes) ->
        bytes

      drop < 3 and bytes != "" ->
        utf8_suffix(binary_part(bytes, 1, byte_size(bytes) - 1), drop + 1)

      true ->
        ""
    end
  end

  defp pointer_token(key),
    do: key |> to_string() |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  defp owned_directory(directory) do
    case File.mkdir(directory) do
      :ok ->
        File.chmod(directory, 0o700)

      {:error, :eexist} ->
        if File.dir?(directory),
          do: :ok,
          else: {:error, "review packet directory is not a directory: #{directory}"}

      {:error, reason} ->
        {:error, "could not create review packet directory: #{inspect(reason)}"}
    end
  end

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- IO.binwrite(io, bytes), :ok <- :file.sync(io) do
            :ok
          else
            {:error, reason} -> {:error, "could not write review packet: #{inspect(reason)}"}
          end
        after
          File.close(io)
        end

      {:error, :eexist} ->
        {:error, "review packet integrity failure: #{path} already exists"}

      {:error, reason} ->
        {:error, "could not create review packet: #{inspect(reason)}"}
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
