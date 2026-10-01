defmodule Kogen.Shaping.Store do
  @moduledoc """
  The durable, Git-ignored state of one headless Shaping session under
  `<root>/.kogen/runtime/shaping/<ID>/`: `session.json` (schema 1),
  append-only `events.jsonl`, the input journal `inputs/`, the idempotency
  journal `requests/` (and `start-requests/` beside the sessions), the
  approval journal `approvals/`, audit notices `notices/`, the raw provider
  streams `turns/` and `runner.log`.

  Every JSON rewrite is atomic (tmp file, then rename); inputs and request
  records are created exclusively and an existing input is never edited.
  """

  alias Kogen.ShapingAudit.{HeadlessInput, Lock}

  @schema 1
  @runtime ".kogen/runtime/shaping"
  @request_effect_wait_ms 2_000

  @doc "The sessions directory of a checkout."
  def sessions_dir(root), do: Path.join(root, @runtime)

  @doc "The directory of session `id`."
  def session_dir(root, id), do: Path.join(sessions_dir(root), id)

  @doc "The schema of `session.json`."
  def schema, do: @schema

  @doc "Reads `session.json`: `{:ok, map}`, `{:error, :missing}` or `{:error, :schema}`."
  def read_session(dir) do
    case read_json(Path.join(dir, "session.json")) do
      {:ok, %{"schema" => @schema} = session} -> {:ok, session}
      {:ok, _other} -> {:error, :schema}
      {:error, _reason} -> {:error, :missing}
    end
  end

  @doc "Atomically rewrites `session.json` with `updated_at`."
  def write_session!(dir, session) do
    session = Map.put(session, "updated_at", now())
    write_json!(Path.join(dir, "session.json"), session)
    session
  end

  @doc "Reads, updates with `fun` and rewrites `session.json`."
  def update_session!(dir, fun) do
    {:ok, session} = read_session(dir)
    write_session!(dir, fun.(session))
  end

  @doc "Appends one event to `events.jsonl`."
  def event!(dir, event, fields \\ %{}) do
    line = Jason.encode!(Map.merge(%{"at" => now(), "event" => event}, fields))
    File.write!(Path.join(dir, "events.jsonl"), line <> "\n", [:append])
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> [decoded]
      _ -> []
    end
  end

  @doc "The recorded events."
  def events(dir) do
    case File.read(Path.join(dir, "events.jsonl")) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)

      {:error, _reason} ->
        []
    end
  end

  # --- inputs --------------------------------------------------------------

  @doc "Four-digit input number."
  def pad(n), do: n |> Integer.to_string() |> String.pad_leading(4, "0")

  @doc "The stable input id `in-NNNN-<first 8 hex of sha256>`."
  def input_id(n, bytes), do: "in-#{pad(n)}-#{binary_part(sha256(bytes), 0, 8)}"

  @doc """
  Accepts input bytes for request `rid`. The number is bound to the request
  first: an existing `inputs/NNNN.claim` naming `rid` (left by an earlier,
  interrupted attempt of the same request) is reused, otherwise the next
  free number is claimed by exclusive creation of that claim file. Then
  `on_claim` records the number (on its request), `inputs/NNNN.md` is written
  and finally `inputs/NNNN.json`. An input is accepted only once both
  exist, so a crash at any point leaves at most one number bound to `rid`.
  Callers serialize attempts of one request (`with_lock/3`).
  """
  def accept_input!(dir, bytes, meta, rid, on_claim \\ fn _n -> :ok end) do
    inputs = Path.join(dir, "inputs")
    File.mkdir_p!(inputs)
    n = claimed_by(inputs, rid) || claim(inputs, rid, next_number(inputs))
    on_claim.(n)
    write_input_bytes!(inputs, n, bytes)
    write_input_meta!(dir, n, bytes, meta)
  end

  @doc "The input number bound to request `rid`, or nil."
  def claimed_input(dir, rid), do: claimed_by(Path.join(dir, "inputs"), rid)

  defp claimed_by(inputs, rid) do
    case File.ls(inputs) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/^\d{4}\.claim$/, &1))
        |> Enum.sort()
        |> Enum.find_value(&claim_of(inputs, &1, rid))

      {:error, _reason} ->
        nil
    end
  end

  defp claim_of(inputs, name, rid) do
    case read_json(Path.join(inputs, name)) do
      {:ok, %{"request_id" => ^rid}} -> String.to_integer(String.slice(name, 0, 4))
      _other -> nil
    end
  end

  defp write_input_bytes!(inputs, n, bytes) do
    path = Path.join(inputs, "#{pad(n)}.md")

    case File.read(path) do
      {:ok, ^bytes} ->
        :ok

      _missing_or_torn ->
        tmp = "#{path}.tmp-#{System.pid()}-#{System.unique_integer([:positive])}"
        File.write!(tmp, bytes)
        File.rename!(tmp, path)
    end
  end

  @doc "Writes (or rewrites identically) the metadata of claimed input `n`."
  def write_input_meta!(dir, n, bytes, meta) do
    record =
      Map.merge(meta, %{
        "id" => input_id(n, bytes),
        "number" => n,
        "sha256" => sha256(bytes)
      })

    write_json!(Path.join([dir, "inputs", "#{pad(n)}.json"]), record)
    record
  end

  defp claim(inputs, rid, n) do
    case File.open(Path.join(inputs, "#{pad(n)}.claim"), [:write, :exclusive, :binary]) do
      {:ok, io} ->
        IO.binwrite(io, Jason.encode!(%{"request_id" => rid, "at" => now()}))
        :ok = :file.sync(io)
        File.close(io)
        n

      {:error, :eexist} ->
        claim(inputs, rid, n + 1)
    end
  end

  defp input_number(name) do
    case Regex.run(~r/^(\d{4})\.(?:md|claim)$/, name) do
      [_, digits] -> [String.to_integer(digits)]
      _ -> []
    end
  end

  defp next_number(inputs) do
    case File.ls(inputs) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&input_number/1)
        |> Enum.max(fn -> 0 end)
        |> Kernel.+(1)

      {:error, _reason} ->
        1
    end
  end

  defp read_input(inputs, name) do
    number = String.slice(name, 0, 4)

    with {:ok, meta} <- read_json(Path.join(inputs, name)),
         {:ok, bytes} <- File.read(Path.join(inputs, number <> ".md")) do
      n = String.to_integer(number)

      [
        meta
        |> Map.put("number", n)
        |> Map.put("id", input_id(n, bytes))
        |> Map.put("text", bytes)
      ]
    else
      _ -> []
    end
  end

  @doc "Every accepted input (both files present), ordered by number."
  def inputs(dir) do
    inputs = Path.join(dir, "inputs")

    case File.ls(inputs) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/^\d{4}\.json$/, &1))
        |> Enum.sort()
        |> Enum.flat_map(&read_input(inputs, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc "Accepted inputs of kind `message`."
  def messages(dir), do: Enum.filter(inputs(dir), &(&1["kind"] == "message"))

  @doc "Message IDs recorded once with a byte-exact frame in `questions_text`."
  def recorded(dir, questions_text),
    do: HeadlessInput.recorded(questions_text, messages(dir))

  @doc "Accepted messages without exactly one byte-exact recording entry."
  def unrecorded_messages(dir, questions_text) do
    recorded = recorded(dir, questions_text)
    Enum.reject(messages(dir), &(Map.get(recorded, &1["id"]) == 1))
  end

  @doc "The brief (input 0001)."
  def brief(dir), do: Enum.find(inputs(dir), &(&1["kind"] == "brief"))

  @doc "Appends an offer record for input `n`."
  def offer!(dir, n, record) do
    path = Path.join([dir, "inputs", "#{pad(n)}.offers.jsonl"])
    File.write!(path, Jason.encode!(Map.put_new(record, "at", now())) <> "\n", [:append])
  end

  @doc "The offer records of input `n`."
  def offers(dir, n) do
    case File.read(Path.join([dir, "inputs", "#{pad(n)}.offers.jsonl"])) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)

      {:error, _reason} ->
        []
    end
  end

  # --- requests --------------------------------------------------------------

  @doc "The request record path of `rid` (session requests, or start requests when `dir` is nil)."
  def request_path(root, nil, rid),
    do: Path.join([sessions_dir(root), "start-requests", rid <> ".json"])

  def request_path(_root, dir, rid), do: Path.join([dir, "requests", rid <> ".json"])

  @doc """
  Creates the request record exclusively, or returns the existing one:
  `{:new, record}` or `{:existing, record}`.
  """
  def open_request(path, record) do
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        IO.binwrite(io, Jason.encode!(record))
        :ok = :file.sync(io)
        File.close(io)
        {:new, record}

      {:error, :eexist} ->
        case read_json(path) do
          {:ok, existing} ->
            {:existing, existing}

          # A record torn by a crash mid-create is only ever ours to redo.
          {:error, _reason} ->
            write_json!(path, record)
            {:new, record}
        end
    end
  end

  @doc "Atomically rewrites a request record."
  def write_request!(path, record), do: write_json!(path, record)

  @doc "All readable request records for a session, ordered by receipt time."
  def requests(dir) do
    dir
    |> Path.join("requests/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read_json(path) do
        {:ok, %{} = request} -> [Map.put(request, "_path", path)]
        _ -> []
      end
    end)
    |> Enum.sort_by(&{&1["received_at"] || "", &1["request_id"] || ""})
  end

  @doc "Cancellation request records that have reserved an unsettled effect."
  def unsettled_cancellations(dir) do
    Enum.filter(requests(dir), fn request ->
      request["command"] == "cancel" and
        get_in(request, ["effect", "status"]) in ["pending", "uncertain"]
    end)
  end

  @doc "Whether an accepted cancellation still blocks new session work."
  def cancellation_busy?(dir), do: unsettled_cancellations(dir) != []

  @doc "Updates one cancellation effect under its request lock, preserving its replay outcome."
  def update_cancellation!(dir, request_id, update) when is_function(update, 1) do
    path = request_path(nil, dir, request_id)

    with_lock(request_lock(path), @request_effect_wait_ms, fn ->
      case read_json(path) do
        {:ok, %{"command" => "cancel", "request_id" => ^request_id} = request} ->
          effect = Map.merge(request["effect"] || %{}, update.(request["effect"] || %{}))
          write_request!(path, Map.put(request, "effect", effect))
          :ok

        _ ->
          {:error, :request_missing}
      end
    end)
  end

  @doc "Settles every pending cancellation after custody proves its groups absent."
  def settle_cancellations!(dir, settlement) do
    unsettled_cancellations(dir)
    |> Enum.map(fn request ->
      request_id = request["request_id"]

      update_cancellation!(dir, request_id, fn effect ->
        Map.merge(effect, %{
          "status" => "settled",
          "settled_at" => now(),
          "settlement" => settlement
        })
      end)
    end)
    |> then(fn results ->
      if Enum.all?(results, &(&1 == {:ok, :ok})), do: :ok, else: {:error, results}
    end)
  end

  @doc "The lock serializing every attempt of one request (see `with_lock/3`)."
  def request_lock(request_path), do: request_path <> ".lock"

  @doc """
  The session's short input/commit lock: held while a message stores its
  input and while an approval makes its final check and rename, so no input
  is accepted between an approval's last check and its commit. It is not the
  session lock (a message never waits for a provider turn).
  """
  def commit_lock(dir), do: Path.join(dir, "commit.lock")

  @doc """
  Runs `fun` holding the exclusive lock file `path` and returns
  `{:ok, result}`, or `{:error, :busy}` when a live holder keeps it past
  `wait_ms`. The lock records the holder's OS pid and start time; a lock
  whose holder is gone is reclaimed.
  """
  def with_lock(path, wait_ms, fun) do
    File.mkdir_p!(Path.dirname(path))
    token = "#{System.pid()}-#{System.unique_integer([:positive])}"
    deadline = System.monotonic_time(:millisecond) + wait_ms

    case Lock.with_lock(path, wait_ms, fn ->
           with_file_lock(path, token, deadline, fun)
         end) do
      {:ok, result} -> result
      {:error, :busy} -> {:error, :busy}
    end
  end

  defp with_file_lock(path, token, deadline, fun) do
    case take_lock(path, token, deadline) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          release_lock(path, token)
        end

      :busy ->
        {:error, :busy}
    end
  end

  defp take_lock(path, token, deadline) do
    pid = System.pid()

    holder =
      Jason.encode!(%{
        "pid" => String.to_integer(pid),
        "started_at" => Kogen.ProcessCustody.process_start(pid),
        "token" => token
      })

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        IO.binwrite(io, holder)
        File.close(io)
        :ok

      {:error, :eexist} ->
        cond do
          stale_lock?(path) ->
            observe(:stale_lock)
            reclaim_lock(path)
            take_lock(path, token, deadline)

          System.monotonic_time(:millisecond) >= deadline ->
            :busy

          true ->
            Process.sleep(20)
            take_lock(path, token, deadline)
        end
    end
  end

  defp stale_lock?(path) do
    case read_json(path) do
      {:ok, %{"pid" => pid, "started_at" => ""}} when is_integer(pid) ->
        elem(System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true), 1) != 0

      {:ok, %{"pid" => pid, "started_at" => started}} when is_integer(pid) ->
        Kogen.ProcessCustody.process_start(pid) != started

      # Torn by a holder killed mid-write: stale once it is not brand new.
      _unreadable ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > 5
          _gone -> false
        end
    end
  end

  # The permanent kernel guard stays held through this check, deletion,
  # acquisition, callback and release. A delayed reclaimer cannot move a
  # newly live owner's lock, and there is no best-effort restoration gap.
  defp reclaim_lock(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "reclaim lock", path: path
    end
  end

  defp observe(phase) do
    case Process.get({__MODULE__, :observer}) do
      fun when is_function(fun, 1) -> fun.(phase)
      _ -> :ok
    end
  end

  defp release_lock(path, token) do
    case read_json(path) do
      {:ok, %{"token" => ^token}} -> File.rm(path)
      _other -> :ok
    end
  end

  # --- helpers -----------------------------------------------------------------

  @doc "Reads a JSON file."
  def read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes) do
      {:ok, data}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Atomically writes JSON (tmp file, then rename)."
  def write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = "#{path}.tmp-#{System.pid()}-#{System.unique_integer([:positive])}"
    File.write!(tmp, Jason.encode!(data, pretty: true) <> "\n")
    File.rename!(tmp, path)
  end

  @doc "Lowercase hex sha256."
  def sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc "UTC now, ISO 8601."
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
