defmodule Kogen.ShapeEvidence do
  @moduledoc "Append-only native shaping/refinement observations. Bytes are not tokens."
  def start(dir, slug \\ nil) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "events.ndjson"), "", [:append])

    Process.put(:shape_evidence, %{
      dir: dir,
      slug: slug,
      start: now(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      intervals: %{},
      event_offset: file_size(Path.join(dir, "events.ndjson"))
    })

    for kind <- ~w(setup acceptance quint), do: Process.delete({:shape_count, kind})
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  def now, do: System.monotonic_time(:millisecond)

  def record(event) do
    event =
      if event[:event] == "provider_call" and Process.get(:provider_attempt_metadata) do
        meta = Process.delete(:provider_attempt_metadata)
        event |> Map.put(:provider, meta) |> Map.put(:error, meta.error)
      else
        event
      end

    if s = Process.get(:shape_evidence) do
      File.write!(Path.join(s.dir, "events.ndjson"), JSON.encode!(event) <> "\n", [:append])
    end
  end

  def count(kind) do
    Process.put({:shape_count, kind}, count_value(kind) + 1)
  end

  def count_value(kind), do: Process.get({:shape_count, kind}, 0)

  def timed(phase, fun) do
    t = now()

    try do
      fun.()
    after
      interval(phase, t, now())
    end
  end

  def interval(phase, a, b) do
    if s = Process.get(:shape_evidence) do
      Process.put(
        :shape_evidence,
        put_in(s, [:intervals, phase], Map.get(s.intervals, phase, []) ++ [{a, b}])
      )
    end
  end

  def offset(t), do: t - (Process.get(:shape_evidence) || %{start: t}).start

  def provider(role, job, revision, scope, config, fun) do
    t = now()

    base = %{
      event: "provider_call",
      role: role,
      job: job,
      revision: revision,
      scope: scope,
      configured_model: config.model,
      effective_model: nil,
      configured_effort: config.effort,
      effective_effort: nil,
      started_ms: offset(t)
    }

    Process.put(:provider_conversation_scope, Process.get(:shape_evidence).dir)

    Process.put(:provider_context, %{
      phase: role,
      role: role,
      slug: Process.get(:shape_evidence).slug
    })

    Process.put(:shape_provider_context, base)
    Process.put(:shape_transport_calls, 0)

    try do
      r = fun.()
      ended = now()

      if Process.get(:shape_transport_calls) == 0,
        do:
          record(
            Map.merge(base, %{
              status: "completed",
              wall_ms: ended - t,
              usage: Map.get(r, :known_usage, r.usage)
            })
          )

      if Process.get(:shape_transport_calls) == 0, do: interval("model", t, ended)
      r
    rescue
      e ->
        ended = now()

        if Process.get(:shape_transport_calls) == 0,
          do:
            record(
              Map.merge(base, %{
                status: "failed",
                wall_ms: ended - t,
                usage: unknown(),
                error: Exception.message(e)
              })
            )

        if Process.get(:shape_transport_calls) == 0, do: interval("model", t, ended)
        reraise e, __STACKTRACE__
    catch
      {:cancel, signal} ->
        ended = now()

        if Process.get(:shape_transport_calls) == 0,
          do:
            record(
              Map.merge(base, %{
                status: "cancelled",
                wall_ms: ended - t,
                usage: unknown(),
                error: %{signal: signal}
              })
            )

        if Process.get(:shape_transport_calls) == 0, do: interval("model", t, ended)
        throw({:cancel, signal})
    after
      Process.delete(:shape_provider_context)
      Process.delete(:shape_transport_calls)
    end
  end

  # Each actual main transport attempt is separate evidence, including recovery.
  # Workers already wrap their single attempt and do not install this context.
  def transport(fun) do
    if base = Process.get(:shape_provider_context) do
      t = now()
      Process.put(:shape_transport_calls, Process.get(:shape_transport_calls, 0) + 1)
      base = Map.put(base, :started_ms, offset(t))

      try do
        result = fun.()

        {status, usage, error} =
          case result do
            {:ok, r} -> {"completed", r.known_usage, nil}
            {kind, detail} -> {"failed", unknown(), %{reason: kind, detail: detail}}
          end

        record(
          Map.merge(base, %{
            event: "provider_call",
            status: status,
            usage: usage,
            error: error,
            wall_ms: now() - t
          })
        )

        result
      catch
        kind, reason ->
          status = if match?({:cancel, _}, reason), do: "cancelled", else: "failed"

          record(
            Map.merge(base, %{
              status: status,
              usage: unknown(),
              error: inspect(reason),
              wall_ms: now() - t
            })
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        interval("model", t, now())
      end
    else
      fun.()
    end
  end

  def unknown, do: %{input: nil, cached: nil, output: nil, reasoning: nil}

  def probe(fun, metadata \\ %{}) do
    t = now()

    try do
      result = fun.()
      ended = now()

      record(
        Map.merge(metadata, %{
          event: "probe_result",
          started_ms: offset(t),
          wall_ms: ended - t,
          status: if(probe_passed?(result), do: "completed", else: "failed"),
          timeout:
            if(is_map(result),
              do: result.timed_out,
              else: String.contains?(result, "timed_out: true")
            ),
          detail: result
        })
      )

      interval("probe", t, ended)
      result
    catch
      kind, reason ->
        ended = now()

        record(
          Map.merge(metadata, %{
            event: "probe_result",
            started_ms: offset(t),
            wall_ms: ended - t,
            status: if(match?({:cancel, _}, reason), do: "cancelled", else: "failed"),
            detail: inspect(reason)
          })
        )

        interval("probe", t, ended)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp probe_passed?(%{status: status}), do: status == 0
  defp probe_passed?(result), do: String.starts_with?(result, "exit status: 0\n")

  def union(intervals) do
    intervals
    |> Enum.sort()
    |> Enum.reduce({0, nil}, fn {a, b}, {total, last} ->
      {total + max(0, b - max(a, last || a)), max(b, last || b)}
    end)
    |> elem(0)
  end

  def finish do
    if s = Process.get(:shape_evidence) do
      {:ok, file} = File.open(Path.join(s.dir, "events.ndjson"), [:read, :binary])

      events =
        try do
          :file.position(file, s.event_offset)

          IO.binread(file, :eof)
          |> then(fn bytes -> if bytes == :eof, do: "", else: bytes end)
          |> String.split("\n", trim: true)
          |> Enum.map(&JSON.decode!/1)
        after
          File.close(file)
        end

      calls = Enum.filter(events, &(&1["event"] == "provider_call"))

      known =
        Map.new(~w(input cached output reasoning), fn k ->
          {k,
           calls
           |> Enum.reject(&(get_in(&1, ["provider", "usage_state"]) == "inconsistent"))
           |> Enum.map(& &1["usage"][k])
           |> Enum.filter(&is_integer/1)
           |> Enum.sum()}
        end)

      record(%{
        event: "usage_totals",
        known: known,
        unknown_calls:
          Enum.count(calls, fn c -> Enum.any?(c["usage"], fn {_, v} -> is_nil(v) end) end)
      })

      for phase <- ~w(setup preparation model probe readiness) do
        record(%{
          event: "phase_duration",
          phase: phase,
          wall_ms:
            union(
              if phase in ~w(model probe) do
                type = if phase == "model", do: "provider_call", else: "probe_result"

                for e <- events,
                    e["event"] == type,
                    do: {e["started_ms"], e["started_ms"] + e["wall_ms"]}
              else
                Map.get(s.intervals, phase, [])
              end
            )
        })
      end

      record(%{
        event: "phase_duration",
        phase: "shape",
        timestamp: s.timestamp,
        wall_ms: now() - s.start
      })

      record(%{
        event: "session_end",
        elapsed_ms: now() - s.start,
        provider_calls: length(calls),
        probe_count: Enum.count(events, &(&1["event"] == "probe_result")),
        setup_executions: count_value("setup"),
        acceptance_executions: count_value("acceptance"),
        model_executions: count_value("quint")
      })

      Process.delete(:shape_evidence)
    end
  end
end
