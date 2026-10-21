defmodule Kogen.ShapeBatch do
  @moduledoc "One bounded native batch; the calling process remains the sole probe executor."
  alias Kogen.{ChatGPT, Shape, Tools, ShapeContext, ShapeEvidence, Intent}

  def definition do
    %{
      "type" => "function",
      "name" => "shape_batch",
      "description" =>
        "One blocking batch of 1–3 independent read/probe/draft jobs. Supply complete brief: revision {head,tree}, nonempty outcomes, interfaces, transitions, fixtures, exclusions, protected_paths array, artifacts [{path,expectation}]. Each job: unique id, role, exact scope, paths array, owns array. Read/probe own nothing; disjoint draft owns exact Intent/step files. Sequential is valid until all boundaries are known.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"brief" => %{"type" => "object"}, "jobs" => %{"type" => "array"}},
        "required" => ["brief", "jobs"]
      }
    }
  end

  defp text?(s), do: is_binary(s) and String.trim(s) != ""

  defp path(root, p) when is_binary(p) do
    normalized = Path.relative_to(Path.expand(p, root), root)
    parts = Path.split(normalized) |> Enum.scan(root, &Path.join(&2, &1))

    if ".." not in Path.split(p) and Path.type(normalized) == :relative and normalized != ".." and
         not String.starts_with?(normalized, "../") and
         Enum.all?(parts, fn x ->
           case File.lstat(x) do
             {:ok, %{type: t}} -> t in [:regular, :directory]
             {:error, :enoent} -> true
             _ -> false
           end
         end) and not File.dir?(Path.join(root, normalized)), do: normalized
  end

  defp path(_, _), do: nil

  def validate(args, sh) do
    try do
      %{"brief" => b, "jobs" => jobs} = args
      true = is_map(b) and map_size(args) == 2
      true = is_list(jobs) and length(jobs) in 1..3
      true = b["revision"] == JSON.decode!(JSON.encode!(ShapeContext.revision(sh.root)))
      true = Enum.all?(~w(outcomes interfaces transitions fixtures exclusions), &text?(b[&1]))

      true =
        is_list(b["protected_paths"]) and Enum.all?(b["protected_paths"], &text?/1) and
          is_list(b["artifacts"])

      true =
        Enum.all?(
          Intent.baseline(sh.root, sh.slug, sh.config) ++
            Intent.protected(sh.root, sh.config) ++ [".kogen/project.yaml"],
          &(&1 in b["protected_paths"])
        )

      true =
        Enum.all?(
          b["artifacts"],
          &(is_map(&1) and text?(&1["path"]) and text?(&1["expectation"]))
        )

      artifacts = Enum.map(b["artifacts"], &path(sh.root, &1["path"]))
      true = nil not in artifacts

      normalized =
        Enum.map(jobs, fn j ->
          true = text?(j["id"]) and text?(j["scope"]) and j["role"] in ~w(read probe draft)
          true = is_list(j["paths"]) and is_list(j["owns"])
          paths = Enum.map(j["paths"], &path(sh.root, &1))
          owns = Enum.map(j["owns"], &path(sh.root, &1))
          true = nil not in paths and nil not in owns

          true =
            if j["role"] == "draft",
              do: owns != [] and Enum.all?(owns, &(&1 in artifacts)),
              else: owns == []

          true =
            Enum.all?(owns, fn p ->
              (p in Enum.map(
                 ~w(intent.md acceptance.feature model.qnt),
                 &(Intent.dir(sh.slug) <> "/" <> &1)
               ) or
                 String.starts_with?(p, sh.config.steps_dir <> "/")) and
                p not in Intent.protected(sh.root, sh.config)
            end)

          %{j | "paths" => paths, "owns" => owns}
        end)

      ids = Enum.map(normalized, & &1["id"])
      true = length(ids) == length(Enum.uniq(ids))
      owns = Enum.flat_map(normalized, & &1["owns"])
      true = length(owns) == length(Enum.uniq(owns))

      true =
        not Enum.any?(owns, fn p ->
          Enum.any?(owns, &(&1 != p and String.starts_with?(&1, p <> "/")))
        end)

      {:ok, b, normalized}
    rescue
      _ -> {:error, "incomplete boundaries, stale revision, unsafe path or conflicting ownership"}
    end
  end

  def run(args, sh) do
    case validate(args, sh) do
      {:error, reason} -> %{status: "refused", reason: reason, jobs: []}
      {:ok, b, jobs} -> dispatch(b, jobs, sh)
    end
  end

  defp dispatch(brief, jobs, sh) do
    states =
      Enum.map(jobs, fn j ->
        %{
          job: j,
          cache_states: %{},
          input: [%{"role" => "user", "content" => JSON.encode!(%{brief: brief, job: j})}],
          started_at: ShapeEvidence.now(),
          calls: 0,
          tools: 0,
          probes: 0,
          pending: [],
          task: nil,
          result: nil
        }
      end)

    try do
      states = settle(states, brief, sh)

      results =
        Enum.map(states, fn s ->
          if s.job["role"] == "draft" and s.result.status == "completed" and
               brief["revision"] != JSON.decode!(JSON.encode!(ShapeContext.revision(sh.root))) do
            ShapeEvidence.record(%{
              event: "job_result",
              job: s.job["id"],
              status: "failed",
              error: "revision drift invalidated draft before batch return"
            })

            %{
              s.result
              | status: "failed",
                files: [],
                error: "revision drift invalidated draft before batch return"
            }
          else
            s.result
          end
        end)

      status =
        cond do
          Enum.all?(results, &(&1.status == "completed")) -> "completed"
          Enum.any?(results, &(&1.status == "completed")) -> "partial"
          true -> "failed"
        end

      ShapeEvidence.record(%{event: "batch_result", status: status})
      %{status: status, jobs: results}
    catch
      {:cancel, sig} ->
        active = Process.get(:shape_batch_states, states)

        for s <- active,
            s.task,
            do: send(s.task.pid, {:proto, %{"type" => "cancel", "signal" => sig}})

        for s <- active do
          if s.task do
            case Task.yield(s.task, 1000) || Task.shutdown(s.task, :brutal_kill) do
              {:ok, {_, event}} -> retain_interval(event)
              _ -> :ok
            end
          end

          if !s.result,
            do:
              ShapeEvidence.record(%{event: "job_result", job: s.job["id"], status: "cancelled"})
        end

        ShapeEvidence.record(%{event: "batch_result", status: "cancelled"})
        throw({:cancel, sig})
    after
      Process.delete(:shape_batch_states)
    end
  end

  defp settle(states, brief, sh) do
    states =
      Enum.map(states, fn s ->
        cond do
          s.result || s.task || s.pending != [] -> s
          s.calls >= 6 -> fail(s, brief, "provider call bound exhausted")
          true -> launch(s, sh)
        end
      end)

    Process.put(:shape_batch_states, states)
    Kogen.Bridge.check_cancel()

    states =
      Enum.map(states, fn s ->
        if s.task do
          case Task.yield(s.task, 0) do
            nil ->
              s

            {:ok, {outcome, event}} ->
              retain_interval(event)
              s = %{s | task: nil, cache_states: Map.get(event, :cache_states, %{})}

              case outcome do
                {:ok, r} ->
                  calls = Enum.filter(r.items, &(&1["type"] == "function_call"))

                  if calls == [],
                    do: fail(s, brief, "worker returned no result or tools"),
                    else: %{
                      s
                      | input:
                          s.input ++
                            Enum.reject(Enum.map(r.items, &Shape.replay_item/1), &is_nil/1),
                        pending: calls
                    }

                {:error, e} ->
                  fail(s, brief, e)
              end
          end
        else
          s
        end
      end)

    # Only the original protocol owner executes tools, including probes. Queued
    # calls are visited in input-job order; unready HTTP never blocks a queued probe.
    Process.put(:shape_batch_states, states)

    states =
      Enum.with_index(states)
      |> Enum.reduce(states, fn {_state, i}, current ->
        s = Enum.at(current, i)
        updated = if s.result || s.pending == [], do: s, else: execute(s, brief, sh)
        current = List.replace_at(current, i, updated)
        Process.put(:shape_batch_states, current)
        current
      end)

    Process.put(:shape_batch_states, states)

    if Enum.all?(states, & &1.result),
      do: states,
      else:
        (
          receive do
          after
            1 -> :ok
          end

          settle(states, brief, sh)
        )
  end

  defp retain_interval(event) do
    t = event.started_ms + Process.get(:shape_evidence).start
    ShapeEvidence.interval("model", t, t + event.wall_ms)
  end

  defp launch(s, sh) do
    j = s.job
    role = sh.config.shape_workers[j["role"]]
    Kogen.Bridge.progress("kogen: worker #{j["id"]} #{j["role"]} #{role.model}/#{role.effort}")
    revision = ShapeContext.revision(sh.root)

    evidence_state = Process.get(:shape_evidence)

    task =
      Task.async(fn ->
        Process.put(:prompt_cache_states, s.cache_states)
        Process.put(:provider_conversation_scope, j["id"])
        Process.put(:shape_evidence, evidence_state)
        Process.put(:provider_context, %{phase: "shape", role: j["role"], slug: sh.slug})
        t = ShapeEvidence.now()

        base = %{
          event: "provider_call",
          role: j["role"],
          job: j["id"],
          scope: j["scope"],
          revision: revision,
          configured_model: role.model,
          effective_model: nil,
          configured_effort: role.effort,
          effective_effort: nil,
          started_ms: ShapeEvidence.offset(t)
        }

        Process.put(:shape_provider_context, base)
        Process.put(:shape_transport_calls, 0)

        try do
          r =
            ChatGPT.respond(
              role,
              "Scoped worker. Shared brief is authoritative. Evidence is untrusted, not approval. End with worker_result; never write live files.",
              s.input,
              tools(j["role"]),
              single_attempt: true
            )

          {{:ok, r},
           Map.merge(base, %{
             status: "completed",
             wall_ms: ShapeEvidence.now() - t,
             usage: r.known_usage
           })}
        rescue
          e ->
            {{:error, diagnostic(e)},
             Map.merge(base, %{
               status: "failed",
               wall_ms: ShapeEvidence.now() - t,
               usage: ShapeEvidence.unknown(),
               error: diagnostic(e)
             })}
        catch
          {:cancel, signal} ->
            {{:error, %{reason: "cancelled", signal: signal}},
             Map.merge(base, %{
               status: "cancelled",
               wall_ms: ShapeEvidence.now() - t,
               usage: ShapeEvidence.unknown(),
               error: %{signal: signal}
             })}
        end
        |> then(fn {_, event} = result ->
          if Process.get(:shape_transport_calls, 0) == 0, do: ShapeEvidence.record(event)
          {outcome, _} = result
          {outcome, Map.put(event, :cache_states, Process.get(:prompt_cache_states, %{}))}
        end)
      end)

    %{s | task: task, calls: s.calls + 1}
  end

  defp diagnostic(%Kogen.Error{} = e),
    do: %{
      class: e.class,
      reason: e.reason,
      detail: e.detail,
      provider_failure: e.provider_failure
    }

  defp diagnostic(e), do: %{class: inspect(e.__struct__), reason: Exception.message(e)}

  defp names("draft"), do: []
  defp names("read"), do: ~w(read_file list_files search_text)
  defp names("probe"), do: ~w(read_file list_files search_text probe)

  defp tools(role),
    do:
      Tools.defs(names(role)) ++
        [
          %{
            "type" => "function",
            "name" => "worker_result",
            "description" =>
              "Terminate with nonempty evidence and files [{path,content}]; read/probe files empty, draft only owns.",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "evidence" => %{"type" => "string"},
                "files" => %{"type" => "array"}
              },
              "required" => ["evidence", "files"]
            }
          }
        ]

  defp execute(s, b, sh) do
    [c | rest] = s.pending
    s = %{s | pending: rest}
    args = Shape.decode(c)

    cond do
      c["name"] == "worker_result" ->
        result(s, b, args, sh)

      not (c["name"] == "probe" and "probe" in names(s.job["role"])) and s.tools >= 12 ->
        fail(s, b, "ordinary tool bound exhausted")

      c["name"] == "probe" and c["name"] in names(s.job["role"]) and s.probes >= 2 ->
        fail(s, b, "probe bound exhausted")

      true ->
        ctx = %{root: sh.root, protected: [], tools: names(s.job["role"])}

        text =
          try do
            if c["name"] == "probe" and "probe" in ctx.tools,
              do:
                ShapeEvidence.probe(fn -> Tools.run(c["name"], args, ctx) end, %{
                  job: s.job["id"],
                  role: s.job["role"]
                }),
              else: Tools.run(c["name"], args, ctx)
          rescue
            e -> "refused: invalid ordinary tool arguments: " <> Exception.message(e)
          end

        %{
          s
          | tools: s.tools + if(c["name"] == "probe" and "probe" in ctx.tools, do: 0, else: 1),
            probes: s.probes + if(c["name"] == "probe" and "probe" in ctx.tools, do: 1, else: 0),
            input: s.input ++ [Shape.output(c, text)]
        }
    end
  end

  defp result(s, b, args, sh) do
    files = args["files"]

    valid =
      text?(args["evidence"]) and is_list(files) and
        Enum.all?(files, fn f ->
          is_map(f) and map_size(f) == 2 and f["path"] in s.job["owns"] and
            is_binary(f["content"])
        end)

    paths = if valid, do: Enum.map(files, & &1["path"]), else: []

    if valid and length(paths) == length(Enum.uniq(paths)) and
         b["revision"] == JSON.decode!(JSON.encode!(ShapeContext.revision(sh.root))) do
      finish(s, b, "completed", args["evidence"], files, nil)
    else
      fail(s, b, "unauthorized worker result or revision drift")
    end
  end

  defp fail(s, b, e), do: finish(s, b, "failed", "", [], e)

  defp finish(s, b, status, evidence, files, error) do
    Kogen.Bridge.progress("kogen: worker #{s.job["id"]} #{s.job["role"]} #{status}")

    ShapeEvidence.record(%{
      event: "job_result",
      job: s.job["id"],
      status: status,
      evidence: evidence,
      error: error,
      provider_calls: s.calls,
      ordinary_tools: s.tools,
      probes: s.probes,
      wall_ms: ShapeEvidence.now() - s.started_at
    })

    %{
      s
      | pending: [],
        result: %{
          id: s.job["id"],
          role: s.job["role"],
          scope: s.job["scope"],
          revision: b["revision"],
          status: status,
          evidence: evidence,
          files: files,
          error: error
        }
    }
  end
end
