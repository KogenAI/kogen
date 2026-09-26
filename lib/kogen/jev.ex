defmodule Kogen.Jev do
  @moduledoc """
  The one TypeSafe Jev reading Build asks for after a Developer turn settles.

  Jev reads only the Developer's free-prose notes. It never sees the diff or
  code and never judges implementation. One `POST` asks, in a single request,
  what the Developer says about each controller-listed item: a six-option
  `status:<id>` Choice per scenario and a three-option `objection:<kind>:<id>`
  Choice per scenario, risk and open finding. The instructions, rules and
  option criteria are fixed controller text copied from the calibrated v2
  wording (`evidence/jev-probe/prose_v2.py` of the Approved Intent
  `harden-developer-handoff`).

  The API key is read at call time from the macOS Keychain service
  `dev.kogen.jev` and used only in the `Authorization: Bearer` header. It is
  never logged, retained, returned or included in an error. Every failure is an
  explicit `unavailable` outcome with a precise reason; nothing here ever
  reports a failure as "no objection".

  Offline tests select alternate executables through `KOGEN_JEV_TRANSPORT`
  (a transport replaying recorded responses) and `KOGEN_JEV_SECURITY` (a
  Keychain lookup), in the same way `KOGEN_HARNESS` selects a fake harness.
  Without `KOGEN_JEV_TRANSPORT`, the request goes to the real endpoint with
  verified TLS.
  """
  use Boundary, deps: []

  @model "jev-1.13.0"
  @endpoint "https://api.typesafe.ai/v1/systemone"
  @keychain_service "dev.kogen.jev"
  @timeout_ms 60_000
  # Only a timeout, HTTP 429 or HTTP 529 is retried, and at most once.
  @max_retries 1
  @retry_statuses [429, 529]
  @wording_version "prose-v2"
  @default_security "/usr/bin/security"

  # Calibrated in `evidence/jev-calibration.md` (round 3) of the Approved
  # Intent `harden-developer-handoff`: over repeated real runs of the v2
  # questions, 0.85 gave 0 wrong stops and caught 29 of 30 real objections,
  # whereas 0.8 produced 2 wrong stops. An `objection` answer at or above this
  # confidence stops the Build and returns it to Shaping.
  @objection_threshold 0.85

  @status_options [
    {"unfinished",
     "The Developer states that implementation work it owns for this item is still missing, partial, stubbed or not yet done in this Candidate."},
    {"done", "The Developer presents its own work for this item as complete."},
    {"pending_external",
     "The Developer's own work is complete; what remains is verification, review, a live/paid run, or approval owned by Kogen, a Reviewer, the owner or another party."},
    {"resolved_or_historical",
     "The notes mention incompleteness only as past history, an earlier attempt, retained evidence, or something since fixed."},
    {"objection_only",
     "The Developer says this item cannot be met as approved (contract defect), rather than simply unfinished."},
    {"unclear", "The notes do not say, or are contradictory."}
  ]

  @objection_options [
    {"objection",
     "The Developer says the approved contract for this item cannot be met as written: a required change is outside the allowed or guarded paths, requirements contradict, the proof cannot observe it, an assumption of the approved Intent is false, or it needs a Shaping decision."},
    {"no_objection",
     "The notes raise no contract objection for this item. Unfinished work, pending verification or ordinary difficulties are not objections."},
    {"unclear", "The notes are ambiguous about whether the contract itself is at fault."}
  ]

  @status_rules [
    "Judge only what the notes literally state about this item; do not judge code.",
    "Pending verification, review or live runs owned by someone else is pending_external, not unfinished.",
    "Past or fixed incompleteness is resolved_or_historical."
  ]

  @objection_rules [
    "Judge only what the notes state about this item.",
    "Unfinished work alone is not an objection."
  ]

  @kinds ~w(scenario risk finding)

  @type item :: %{required(String.t()) => String.t()}

  @doc "The pinned Jev model (never an alias)."
  def model, do: @model

  @doc "The systemone endpoint."
  def endpoint, do: @endpoint

  @doc "The macOS Keychain generic-password service holding the TypeSafe API key."
  def keychain_service, do: @keychain_service

  @doc "The fixed per-request timeout in milliseconds."
  def timeout_ms, do: @timeout_ms

  @doc "The calibrated objection threshold; see the module attribute's evidence."
  def objection_threshold, do: @objection_threshold

  @doc "The fixed question wording version."
  def wording_version, do: @wording_version

  @doc "The status options, in the order they are sent."
  def status_options, do: Enum.map(@status_options, &elem(&1, 0))

  @doc "The objection options, in the order they are sent."
  def objection_options, do: Enum.map(@objection_options, &elem(&1, 0))

  @doc """
  Build precondition: succeeds only when the Keychain item exists. It runs the
  lookup without `-w`, so the value is never read, printed or retained.
  """
  @spec key_present(keyword()) :: :ok | {:error, String.t()}
  def key_present(opts \\ []) do
    case security(opts, ["find-generic-password", "-s", @keychain_service]) do
      {:ok, _discarded} ->
        :ok

      :error ->
        {:error,
         "TypeSafe Jev API key missing: the macOS Keychain has no generic password for service `#{@keychain_service}` (or it could not be looked up). Build reads the Developer's notes with Jev and stops before launch without it. Add the key with `security add-generic-password -s #{@keychain_service} -a <account> -w` (it prompts for the key) and run the Build again."}
    end
  end

  @doc """
  The exact request bytes for `notes` and the controller-listed `items`
  (`%{"kind" => kind, "id" => id}` with kind `scenario`, `risk` or `finding`).
  """
  @spec request_body(String.t(), [item()]) :: binary()
  def request_body(notes, items) when is_binary(notes) and is_list(items) do
    item_list =
      Enum.map(items, fn item ->
        Jason.OrderedObject.new([{"kind", item["kind"]}, {"id", item["id"]}])
      end)

    state = Jason.OrderedObject.new([{"developer_notes", notes}, {"items", item_list}])

    Jason.encode!(
      Jason.OrderedObject.new([
        {"model", @model},
        {"state", state},
        {"questions", Jason.OrderedObject.new(questions(items))}
      ])
    )
  end

  @doc "Question ids with their sent options, in request order."
  @spec question_options([item()]) :: [{String.t(), [String.t()]}]
  def question_options(items) do
    Enum.flat_map(items, fn %{"kind" => kind, "id" => id} ->
      objection = {"objection:#{kind}:#{id}", objection_options()}

      if kind == "scenario",
        do: [{"status:#{id}", status_options()}, objection],
        else: [objection]
    end)
  end

  defp questions(items) do
    Enum.flat_map(items, fn %{"kind" => kind, "id" => id} ->
      objection =
        {"objection:#{kind}:#{id}",
         question(
           "According to developer_notes, does the Developer object that the approved contract for #{kind} `#{id}` cannot be met as written?",
           @objection_rules,
           @objection_options
         )}

      if kind == "scenario" do
        [
          {"status:#{id}",
           question(
             "According to developer_notes, what is the state of the Developer's own work on scenario `#{id}`?",
             @status_rules,
             @status_options
           )},
          objection
        ]
      else
        [objection]
      end
    end)
  end

  defp question(task, rules, options) do
    Jason.OrderedObject.new([
      {"type", "choice"},
      {"instructions", Jason.OrderedObject.new([{"task", task}, {"rules", rules}])},
      {"criteria", Jason.OrderedObject.new(options)}
    ])
  end

  @doc """
  Asks Jev once about `notes` for `items` and returns a JSON-safe outcome map:
  `outcome` is `answered` (every asked question has exactly one valid answer)
  or `unavailable` (with a precise `reason`). The outcome retains the exact
  request bytes and digest, every HTTP exchange (status, response, latency),
  usage and the answers. It never contains the key.

  Options (tests only): `:transport` (a function receiving
  `%{url, headers, body, timeout}`), `:security` (an alternate Keychain
  executable) and `:timeout`.
  """
  @spec read_notes(binary(), [item()], keyword()) :: map()
  def read_notes(notes, items, opts \\ []) when is_binary(notes) and is_list(items) do
    base = %{
      "model" => @model,
      "endpoint" => @endpoint,
      "wording_version" => @wording_version,
      "objection_threshold" => @objection_threshold,
      "items" => items,
      "exchanges" => []
    }

    cond do
      not valid_items?(items) ->
        unavailable(base, "controller item list is invalid")

      not String.valid?(notes) ->
        unavailable(base, "the Developer's notes are not valid UTF-8 and cannot be sent")

      true ->
        body = request_body(notes, items)

        base =
          Map.put(base, "request", %{
            "body" => body,
            "sha256" => digest(body),
            "byte_count" => byte_size(body)
          })

        with_key(base, opts, &exchange(base, body, items, &1, opts))
    end
  end

  defp valid_items?(items) do
    items != [] and
      Enum.all?(items, fn
        %{"kind" => kind, "id" => id} = item when map_size(item) == 2 ->
          kind in @kinds and is_binary(id) and id != ""

        _ ->
          false
      end)
  end

  defp with_key(base, opts, function) do
    case security(opts, ["find-generic-password", "-s", @keychain_service, "-w"]) do
      {:ok, output} ->
        case String.trim_trailing(output, "\n") do
          "" -> unavailable(base, "Keychain item `#{@keychain_service}` returned an empty key")
          key -> function.(key)
        end

      :error ->
        unavailable(
          base,
          "Keychain item `#{@keychain_service}` could not be read at call time"
        )
    end
  end

  defp exchange(base, body, items, key, opts) do
    request = %{
      url: @endpoint,
      headers: [
        {"authorization", "Bearer " <> key},
        {"content-type", "application/json"}
      ],
      body: body,
      timeout: Keyword.get(opts, :timeout, @timeout_ms)
    }

    transport = transport(opts)
    {exchanges, final} = send_with_retry(transport, request, key, [], 0)
    base = Map.put(base, "exchanges", exchanges)

    case final do
      {:ok, 200, response} -> answered(base, response, items)
      {:ok, status, response} -> unavailable(base, "HTTP #{status}: #{excerpt(response)}")
      {:error, reason} -> unavailable(base, reason)
    end
  end

  defp send_with_retry(transport, request, key, exchanges, tries) do
    started = System.monotonic_time(:millisecond)
    result = safe_post(transport, request)
    latency = System.monotonic_time(:millisecond) - started
    {record, final} = exchange_record(result, latency, key)
    exchanges = exchanges ++ [record]

    if tries < @max_retries and retryable?(result),
      do: send_with_retry(transport, request, key, exchanges, tries + 1),
      else: {exchanges, final}
  end

  defp safe_post(transport, request) do
    transport.(request)
  rescue
    error -> {:error, {:transport_exception, error.__struct__}}
  catch
    kind, _value -> {:error, {:transport_exception, kind}}
  end

  defp retryable?({:error, :timeout}), do: true
  defp retryable?({:ok, %{status: status}}), do: status in @retry_statuses
  defp retryable?(_result), do: false

  defp exchange_record({:ok, %{status: status, body: body}}, latency, _key)
       when is_integer(status) and is_binary(body) do
    record =
      Map.merge(
        %{"status" => status, "latency_ms" => latency},
        retained_body(body)
      )

    {record, {:ok, status, body}}
  end

  defp exchange_record({:error, :timeout}, latency, _key) do
    {%{"error" => "timeout", "latency_ms" => latency},
     {:error, "timeout after #{@timeout_ms} ms (retried at most #{@max_retries} time)"}}
  end

  defp exchange_record(other, latency, key) do
    reason =
      case other do
        {:error, reason} -> "transport failure: " <> redact(inspect(reason), key)
        _ -> "transport returned an invalid result"
      end

    {%{"error" => reason, "latency_ms" => latency}, {:error, reason}}
  end

  defp retained_body(body) do
    if String.valid?(body),
      do: %{"response_body" => body},
      else: %{"response_body_base64" => Base.encode64(body)}
  end

  defp redact(text, key), do: String.replace(text, key, "[redacted]")

  defp excerpt(body) do
    text = if String.valid?(body), do: body, else: "<non-UTF-8 body>"
    if String.length(text) > 300, do: String.slice(text, 0, 300) <> "...", else: text
  end

  defp answered(base, response, items) do
    with {:ok, decoded} <- decode(response),
         :ok <- same_model(decoded),
         {:ok, answers} <- validate_answers(decoded["answers"], question_options(items)) do
      base
      |> Map.put("outcome", "answered")
      |> Map.put("reason", nil)
      |> Map.put("usage", usage(decoded))
      |> Map.put("answers", answers)
    else
      {:error, reason} -> base |> unavailable(reason) |> Map.put("usage", usage(response))
    end
  end

  # Ordered decoding keeps repeated keys visible: a duplicated answer makes
  # the whole response unavailable instead of silently keeping one of them.
  defp decode(response) do
    case Jason.decode(response, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = decoded} ->
        with :ok <- unique_keys(decoded, "response keys"),
             :ok <- unique_keys(decoded["answers"], "response answers") do
          {:ok, plain(decoded)}
        end

      _ ->
        {:error, "response body is not a JSON object"}
    end
  end

  defp unique_keys(%Jason.OrderedObject{values: values}, label) do
    keys = Enum.map(values, &elem(&1, 0))

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      duplicated -> {:error, "#{label} repeat #{Enum.join(Enum.uniq(duplicated), ", ")}"}
    end
  end

  defp unique_keys(_value, _label), do: :ok

  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {key, value} -> {key, plain(value)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  defp same_model(%{"model" => @model}), do: :ok

  defp same_model(decoded),
    do: {:error, "response names model #{inspect(decoded["model"])}, not #{@model}"}

  defp validate_answers(answers, asked) when is_map(answers) do
    asked_ids = Enum.map(asked, &elem(&1, 0))

    case Map.keys(answers) -- asked_ids do
      [] ->
        Enum.reduce_while(asked, {:ok, %{}}, &collect_answer(answers, &1, &2))

      extra ->
        {:error, "response answers unasked questions: #{Enum.join(Enum.sort(extra), ", ")}"}
    end
  end

  defp validate_answers(_answers, _asked), do: {:error, "response has no answers object"}

  defp collect_answer(answers, {id, options}, {:ok, acc}) do
    case valid_answer(answers[id], options) do
      {:ok, answer} -> {:cont, {:ok, Map.put(acc, id, answer)}}
      {:error, problem} -> {:halt, {:error, "answer for #{id} is #{problem}"}}
    end
  end

  defp valid_answer(nil, _options), do: {:error, "missing"}

  defp valid_answer(%{"choice" => choice, "confidence" => confidence} = answer, options)
       when is_binary(choice) and is_number(confidence) do
    cond do
      choice not in options -> {:error, "invalid (option #{inspect(choice)} was not sent)"}
      confidence < 0 or confidence > 1 -> {:error, "invalid (confidence out of range)"}
      Map.get(answer, "type", "choice") != "choice" -> {:error, "invalid (not a choice)"}
      true -> {:ok, %{"choice" => choice, "confidence" => confidence}}
    end
  end

  defp valid_answer(_answer, _options), do: {:error, "invalid"}

  defp usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp usage(_response), do: nil

  defp unavailable(base, reason) do
    base
    |> Map.put("outcome", "unavailable")
    |> Map.put("reason", reason)
    |> Map.put("answers", nil)
    |> Map.put_new("usage", nil)
  end

  @doc """
  Items whose `objection` answer is at or above the calibrated threshold, as
  `%{"kind", "id", "confidence"}`. An unavailable outcome never objects.
  """
  @spec objections(map()) :: [map()]
  def objections(%{"outcome" => "answered", "answers" => answers, "items" => items}) do
    Enum.flat_map(items, fn %{"kind" => kind, "id" => id} ->
      case answers["objection:#{kind}:#{id}"] do
        %{"choice" => "objection", "confidence" => confidence}
        when confidence >= @objection_threshold ->
          [%{"kind" => kind, "id" => id, "confidence" => confidence}]

        _ ->
          []
      end
    end)
  end

  def objections(_outcome), do: []

  @doc """
  Advisory per-item notes for the fresh Reviewer. They report only what Jev
  read in the Developer's words; they are never findings or verification.
  """
  @spec advisory(map()) :: [map()]
  def advisory(%{"outcome" => "answered", "answers" => answers, "items" => items}) do
    Enum.map(items, fn %{"kind" => kind, "id" => id} ->
      status =
        if kind == "scenario", do: [status_note(id, answers["status:#{id}"])], else: []

      %{
        "kind" => kind,
        "id" => id,
        "notes" => status ++ [objection_note(answers["objection:#{kind}:#{id}"])]
      }
    end)
  end

  def advisory(%{"items" => items, "reason" => reason}) when is_list(items) do
    Enum.map(items, fn item ->
      Map.put(Map.take(item, ["kind", "id"]), "notes", [
        "Jev unavailable: #{reason}; no Developer-notes reading was available"
      ])
    end)
  end

  def advisory(_outcome), do: []

  defp status_note(id, %{"choice" => choice, "confidence" => c}) do
    case choice do
      "unfinished" ->
        "the Developer says #{id} is unfinished (confidence #{format(c)})"

      "done" ->
        "the Developer says its work on #{id} is done (confidence #{format(c)})"

      "pending_external" ->
        "the Developer says its work on #{id} is done and only external verification is pending (confidence #{format(c)})"

      "resolved_or_historical" ->
        "resolved or historical (confidence #{format(c)})"

      "objection_only" ->
        "possible objection (confidence #{format(c)})"

      "unclear" ->
        "unclear (confidence #{format(c)})"
    end
  end

  defp objection_note(%{"choice" => choice, "confidence" => c}) do
    case choice do
      "objection" -> "possible objection (confidence #{format(c)})"
      "no_objection" -> "no objection stated (confidence #{format(c)})"
      "unclear" -> "objection unclear (confidence #{format(c)})"
    end
  end

  @doc false
  def format(confidence), do: :erlang.float_to_binary(confidence / 1, decimals: 2)

  defp security(opts, args) do
    executable =
      Keyword.get(opts, :security) || System.get_env("KOGEN_JEV_SECURITY") || @default_security

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> :error
    end
  rescue
    _error -> :error
  end

  defp transport(opts) do
    case Keyword.get(opts, :transport) do
      nil ->
        case System.get_env("KOGEN_JEV_TRANSPORT") do
          nil -> &network_post/1
          "" -> &network_post/1
          executable -> &executable_post(executable, &1)
        end

      function when is_function(function, 1) ->
        function
    end
  end

  @doc false
  # The transport a Build would use with the current environment.
  def transport_kind do
    case System.get_env("KOGEN_JEV_TRANSPORT") do
      value when value in [nil, ""] -> :network
      executable -> {:executable, executable}
    end
  end

  defp network_post(%{url: url, headers: headers, body: body, timeout: timeout}) do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      request =
        {String.to_charlist(url),
         Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
         ~c"application/json", body}

      options = [timeout: timeout, connect_timeout: timeout, autoredirect: false, ssl: tls()]

      :post
      |> :httpc.request(request, options, body_format: :binary)
      |> httpc_result()
    end
  end

  defp httpc_result({:ok, {{_version, status, _phrase}, _headers, response}}),
    do: {:ok, %{status: status, body: response}}

  defp httpc_result({:error, reason}),
    do: if(timeout_reason?(reason), do: {:error, :timeout}, else: {:error, reason})

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?(:connect_timeout), do: true
  defp timeout_reason?({:failed_connect, details}), do: inspect(details) =~ ":timeout"
  defp timeout_reason?(_reason), do: false

  defp tls do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  # An alternate transport executable for offline tests. The request goes over
  # stdin as a length-prefixed JSON line so no request material touches disk.
  defp executable_post(executable, %{url: url, headers: headers, body: body, timeout: timeout}) do
    payload =
      Jason.encode!(%{
        "url" => url,
        "timeout_ms" => timeout,
        "headers" => Map.new(headers),
        "body" => body
      })

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide
      ])

    Port.command(port, [Integer.to_string(byte_size(payload)), "\n", payload])
    collect(port, [], System.monotonic_time(:millisecond) + timeout)
  rescue
    error -> {:error, {:transport_exception, error.__struct__}}
  end

  defp collect(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [acc, data], deadline)

      {^port, {:exit_status, 0}} ->
        decode_executable(IO.iodata_to_binary(acc))

      {^port, {:exit_status, status}} ->
        {:error, {:transport_exit, status}}
    after
      remaining ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp decode_executable(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => "timeout"}} -> {:error, :timeout}
      {:ok, %{"error" => reason}} -> {:error, reason}
      {:ok, %{"status" => status, "body" => body}} -> {:ok, %{status: status, body: body}}
      _ -> {:error, :invalid_transport_output}
    end
  end

  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
