defmodule Kogen.LocalFacts do
  @moduledoc "Read integration records; never approval or continuation authority."
  alias Kogen.Git

  def package(root, slug, config) do
    paths = Kogen.Intent.baseline(root, slug, config) |> Enum.sort()
    dir = Path.join(root, ".kogen/local/packages")
    File.mkdir_p!(dir)

    atomic(Path.join(dir, slug <> ".json"), %{
      checkout_id: checkout(root)["id"],
      paths: paths,
      sha256: Kogen.Intent.hash(root, paths),
      package_state:
        if(match?({:ok, _, _}, Kogen.Intent.check(root, slug)), do: "valid", else: "invalid")
    })
  end

  def checkout(root) do
    {physical, 0} = System.cmd("pwd", ["-P"], cd: root)
    root = String.trim(physical)
    git = Git.ok!(root, ["rev-parse", "--absolute-git-dir"]) |> String.trim()
    {physical_git, 0} = System.cmd("pwd", ["-P"], cd: git)
    git = String.trim(physical_git)

    %{
      "root" => root,
      "git_dir" => git,
      "id" => Base.encode16(:crypto.hash(:sha256, git), case: :lower)
    }
  end

  def owner(root) do
    path = Path.join(root, ".kogen/local/build.lock")
    token = Process.get({Kogen.Lock, path})
    {birth, 0} = System.cmd("ps", ["-p", System.pid(), "-o", "lstart="])
    %{"pid" => System.pid(), "birth" => String.trim(birth), "token" => token}
  end

  def start(root, slug, run, parent \\ nil, root_run \\ nil) do
    Process.delete(:local_failure)
    c = checkout(root)

    record = %{
      "checkout_id" => c["id"],
      "slug" => slug,
      "run_id" => run.id,
      "resumed_from" => parent,
      "root_run" => root_run || run.id,
      "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "state" => "active",
      "phase" => "startup",
      "verification_pass" => nil,
      "verification" => [],
      "reviews" => [],
      "reason" => nil,
      "blockers" => [],
      "commit" => nil,
      "resume_status" => "requires_validation",
      "owner" => owner(root),
      "locations" => %{
        "candidate" => root,
        "run_dir" => run.dir,
        "log" => run.log,
        "checkpoint" => Path.join(run.dir, "checkpoint.json")
      },
      "evidence_truncated" => false,
      "evidence_locations" => %{"run_dir" => run.dir, "log" => run.log}
    }

    Process.put(
      :usage_phase_clock,
      {"startup", System.monotonic_time(:millisecond),
       DateTime.utc_now() |> DateTime.to_iso8601()}
    )

    Process.put(:local_record, record)
    publish(root, c, record)
    package(root, slug, Kogen.Config.load!(root))
  end

  def inherit(b, previous_run) do
    r = Process.get(:local_record)

    r =
      case File.read(Path.join(b.root, ".kogen/local/facts/#{previous_run.id}.json")) do
        {:ok, bytes} ->
          case JSON.decode(bytes) do
            {:ok, old} when is_map(old) ->
              Enum.reduce(~w(verification reviews), r, fn key, r ->
                entries =
                  for entry <- if(is_list(old[key]), do: Enum.take(old[key], -20), else: []),
                      is_map(entry),
                      do:
                        Map.new(
                          [:n, :green, :tree, :failing, :not_run, :verdict, :findings, :path],
                          fn k -> {k, entry[Atom.to_string(k)]} end
                        )
                        |> Map.reject(fn {_, v} -> v == nil end)

                Map.put(r, key, Enum.take(entries, -20))
              end)

            _ ->
              r
          end

        _ ->
          r
      end

    r = evidence(r, "verification", b.last_pass, :n, previous_run.dir)
    r = evidence(r, "reviews", b.last_review, :n, previous_run.dir)
    Process.put(:local_record, r)
  end

  def failure(e), do: Process.put(:local_failure, e)

  defp blockers(b, outcome) do
    cond do
      b.blocker ->
        [b.blocker]

      b.last_review && b.last_review.verdict == "changes" ->
        Enum.filter(b.last_review.findings, &(&1["severity"] == "blocking"))
        |> Enum.map(&Map.put(&1, "paths", [&1["path"]]))

      outcome != nil && b.continuation.stage in [:startup, :tool, :commit] ->
        [
          %{
            "reason" => "unsafe_boundary",
            "detail" =>
              "uncertain #{b.continuation.stage} boundary; inspect effects and obtain fresh exact approval for a new Build",
            "paths" => [Path.join(b.run.dir, "checkpoint.json")]
          }
        ]

      outcome != nil && Process.get(:local_failure) ->
        e = Process.get(:local_failure)
        [%{"class" => e.class, "reason" => e.reason, "detail" => e.detail, "paths" => e.lines}]

      true ->
        []
    end
  end

  def update(b, phase \\ nil, outcome \\ nil) do
    r = Process.get(:local_record)

    if r && r["run_id"] == b.run.id do
      phase = phase || r["phase"]

      if clock = Process.get(:usage_phase_clock) do
        {old_phase, started, at} = clock

        if old_phase != phase or outcome != nil do
          now = System.monotonic_time(:millisecond)

          Kogen.Run.log(b.run, %{
            event: "phase_duration",
            phase:
              Map.get(%{"building" => "build", "reviewing" => "review"}, old_phase, old_phase),
            timestamp: at,
            wall_ms: now - started
          })

          if outcome == nil,
            do:
              Process.put(
                :usage_phase_clock,
                {phase, now, DateTime.utc_now() |> DateTime.to_iso8601()}
              ),
            else: Process.delete(:usage_phase_clock)
        end
      end

      status =
        cond do
          b.blocker != nil -> "unsupported"
          outcome in ["baseline_changed", "head_moved"] -> "unsupported"
          b.continuation.stage in [:startup, :tool, :commit] -> "unsupported"
          outcome == nil -> "requires_validation"
          true -> "potentially_available"
        end

      r =
        Map.merge(r, %{
          "phase" => phase,
          "verification_pass" => if(phase == "verifying", do: b.pass, else: nil),
          "state" => outcome || "active",
          "reason" => outcome,
          "resume_status" => status,
          "blockers" => blockers(b, outcome),
          "commit" => b.continuation[:commit]
        })

      r = evidence(r, "verification", b.last_pass, :n)
      r = evidence(r, "reviews", b.last_review, :n)
      Process.put(:local_record, r)
      publish(b.root, checkout(b.root), r)
    end

    b
  end

  defp evidence(r, key, value, field),
    do: evidence(r, key, value, field, r["locations"]["run_dir"])

  defp evidence(r, _, nil, _, _), do: r
  defp evidence(r, "reviews", %{verdict: "pending"}, _, _), do: r

  defp evidence(r, key, value, field, artifact_dir) do
    summary =
      if key == "verification",
        do: Map.take(value, [:n, :green, :tree, :failing, :not_run]),
        else: Map.take(value, [:n, :verdict, :findings])

    previous = Enum.find(r[key], &(&1[field] == value[field]))

    artifact_dir =
      if previous && Map.drop(previous, [:path]) == summary,
        do: Path.dirname(previous.path),
        else: artifact_dir

    entries = Enum.reject(r[key], &(&1[field] == value[field])) ++ [summary]

    summary_path =
      if key == "verification",
        do: Path.join(artifact_dir, "acceptance-#{value[field]}.ndjson"),
        else: Path.join(artifact_dir, "review-#{value[field]}.json")

    summary_path =
      if File.regular?(summary_path), do: summary_path, else: Path.join(artifact_dir, "log.jsonl")

    entries = List.update_at(entries, -1, &Map.put(&1, :path, summary_path))

    r
    |> Map.put(key, Enum.take(entries, -20))
    |> Map.put("evidence_truncated", r["evidence_truncated"] || length(entries) > 20)
  end

  defp publish(root, checkout, record) do
    dir = Path.join(root, ".kogen/local")
    File.mkdir_p!(Path.join(dir, "facts"))
    atomic(Path.join(dir, "facts/#{record["run_id"]}.json"), record)

    last = Map.take(record, ["slug", "run_id"])

    active =
      if record["state"] == "active",
        do: Map.take(record, ["slug", "run_id", "phase", "verification_pass"]),
        else: nil

    atomic(Path.join(dir, "context.json"), %{
      "schema_version" => 1,
      "checkout" => checkout,
      "active" => active,
      "last_built" => last,
      "owner" => record["owner"]
    })

    catalog =
      case File.read(Path.join(dir, "catalog.json")) do
        {:ok, bytes} ->
          case JSON.decode(bytes) do
            {:ok, catalog} when is_map(catalog) ->
              Map.filter(catalog, fn {_, r} ->
                is_map(r) and r["checkout_id"] == checkout["id"]
              end)

            _ ->
              %{}
          end

        _ ->
          %{}
      end

    catalog =
      Map.put(
        catalog,
        record["run_id"],
        Map.take(
          record,
          ~w(checkout_id slug run_id started_at state phase resumed_from root_run resume_status owner)
        )
      )

    atomic(Path.join(dir, "catalog.json"), catalog)
    runs = catalog |> Map.values() |> Enum.sort_by(& &1["run_id"])

    atomic(Path.join(dir, "completion.json"), %{
      "inspect" => Enum.take(runs, 100),
      "resume" =>
        runs
        |> Enum.reject(&(&1["resume_status"] == "unsupported" or &1["state"] == "landed"))
        |> Enum.take(100)
    })
  end

  defp atomic(path, value) do
    File.write!(path <> ".tmp", JSON.encode!(value) <> "\n")
    File.rename!(path <> ".tmp", path)
  end
end
