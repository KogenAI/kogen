defmodule Kogen.Stages do
  @moduledoc "Optional approved sequential milestones and contract-bound retained progress."

  def parse(text) do
    {sections, _, _} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], false, nil}, fn line, {sections, active, fence} ->
        cond do
          fence == nil and Regex.match?(~r/^## Stages[ \t\r]*$/, line) ->
            {[[] | sections], true, nil}

          fence == nil and String.starts_with?(line, "## ") ->
            {sections, false, nil}

          true ->
            sections = if active, do: [[line | hd(sections)] | tl(sections)], else: sections

            fence =
              if fence do
                if Regex.match?(~r/^ {0,3}#{fence}[#{String.first(fence)}]*[ \t\r]*$/, line),
                  do: nil,
                  else: fence
              else
                case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line) do
                  [_, marker] -> marker
                  _ -> nil
                end
              end

            {sections, active, fence}
        end
      end)

    case sections do
      [] -> {:ok, nil}
      [lines] -> decode(lines |> Enum.reverse() |> Enum.join("\n"))
      _ -> {:error, "stages: duplicate ## Stages sections"}
    end
  end

  defp decode(body) do
    with [_, json] <- Regex.run(~r/\A\s*```json\s*\n(.*?)\n```\s*\z/s, body),
         {:ok, %{"version" => 1, "stages" => stages} = plan} <- JSON.decode(json),
         true <- Map.keys(plan) |> Enum.sort() == ["stages", "version"],
         true <- is_list(stages) and length(stages) >= 2,
         true <- Enum.all?(stages, &valid_entry?/1),
         ids = Enum.map(stages, & &1["id"]),
         true <- Enum.uniq(ids) == ids do
      {:ok, stages}
    else
      _ ->
        {:error,
         "stages: expected one JSON fence with version 1 and at least two unique stages (id, title, goal, nonempty checks); no extra fields"}
    end
  end

  defp valid_entry?(%{"id" => id, "title" => title, "goal" => goal, "checks" => checks} = s) do
    Enum.sort(Map.keys(s)) == ["checks", "goal", "id", "title"] and
      is_binary(id) and Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, id) and
      nonblank?(title) and nonblank?(goal) and is_list(checks) and checks != [] and
      Enum.all?(checks, &nonblank?/1)
  end

  defp valid_entry?(_), do: false
  defp nonblank?(s), do: is_binary(s) and String.trim(s) != ""

  def initial(nil), do: nil

  def initial(plan),
    do: %{
      "total" => length(plan),
      "completed" => [],
      "active" => hd(plan)["id"],
      "phase" => "stage"
    }

  def navigation(b) do
    case Map.get(b, :stage_progress) do
      nil ->
        ""

      p ->
        stage = Enum.find(b.stage_plan, &(&1["id"] == p["active"]))

        "\nStaged plan progress: #{JSON.encode!(p)}\n" <>
          if(stage,
            do:
              "Active stage #{length(p["completed"]) + 1}/#{p["total"]}: #{JSON.encode!(stage)}\n",
            else: "All scoped stages completed. Continue whole-Intent #{p["phase"]}.\n"
          ) <>
          "Stage evidence is historical for its recorded tree, not current whole-Intent proof.\nHistorical stage evidence: #{JSON.encode!(Enum.map(Map.get(b, :stage_evidence, []), &Map.take(&1, [:stage_id, :stage_index, :tree, :green, :failing, :not_run, :custody])))}\n"
    end
  end

  def phase(b, phase) do
    if Map.get(b, :stage_progress),
      do: Map.update!(b, :stage_progress, &Map.put(&1, "phase", phase)),
      else: b
  end

  def retain(b, evidence) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    path = Path.join(b.run.dir, "stage-#{evidence.n}-#{nonce}.json")
    bytes = JSON.encode!(evidence) <> "\n"
    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      IO.binwrite(io, bytes)
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    Map.put(evidence, :custody, %{"path" => path, "sha256" => Kogen.WorkingContext.hash(bytes)})
  end

  def validate!(b) do
    unless valid?(b) do
      Kogen.Error.raise!(
        "candidate",
        "resume_refused",
        "stage progress/evidence inconsistent with approved plan or private custody",
        1
      )
    end

    b
  end

  defp bound?(b, e) do
    path = e.custody["path"]
    runs = Path.join(b.root, ".kogen/local/runs")
    relative = Path.relative_to(path, runs)

    with [id, name] <- Path.split(relative),
         true <- Regex.match?(~r/^[a-f0-9]{8}$/, id),
         true <- Regex.match?(~r/^stage-#{e.n}-[a-f0-9]{16}\.json$/, name),
         true <- path == Path.join([runs, id, name]),
         true <-
           Enum.all?(
             [
               b.root,
               Path.join(b.root, ".kogen"),
               Path.join(b.root, ".kogen/local"),
               runs,
               Path.dirname(path)
             ],
             fn dir -> match?({:ok, %{type: :directory}}, File.lstat(dir)) end
           ),
         {:ok, %{mode: directory_mode}} <- File.lstat(Path.dirname(path)),
         true <- Bitwise.band(directory_mode, 0o777) == 0o700,
         {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         {:ok, bytes} <- File.read(path) do
      Kogen.WorkingContext.hash(bytes) == e.custody["sha256"] and
        JSON.decode!(bytes) == JSON.decode!(JSON.encode!(Map.delete(e, :custody)))
    else
      _ -> false
    end
  end

  def valid?(b) do
    case parse(b.intent.text) do
      {:ok, nil} ->
        Map.get(b, :stage_progress) == nil and Map.get(b, :stage_plan) == nil and
          Map.get(b, :stage_evidence, []) == []

      {:ok, plan} ->
        valid_progress?(b, plan)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_phase?(phase, continuation) do
    case continuation do
      %{stage: stage} when stage in [:startup, :builder, :builder_verify] ->
        phase in ["stage", "final"]

      %{stage: :tool, owner: :builder} ->
        phase in ["stage", "final"]

      %{stage: stage} when stage in [:review, :review_verify, :review_retry_verify, :commit] ->
        phase == "review"

      %{stage: :tool, owner: :reviewer} ->
        phase == "review"

      %{stage: :landed} ->
        phase == "landed"

      _ ->
        false
    end
  end

  defp valid_progress?(b, plan) do
    p = b.stage_progress
    ids = Enum.map(plan, & &1["id"])
    completed = p["completed"]
    evidence = b.stage_evidence
    greens = Enum.filter(evidence, & &1.green)

    valid_phase?(p["phase"], b.continuation) and
      p["total"] == length(plan) and b.stage_plan == plan and
      is_list(completed) and completed == Enum.take(ids, length(completed)) and
      length(completed) <= length(ids) and
      p["active"] == Enum.at(ids, length(completed)) and
      p["phase"] in if(length(completed) < length(ids),
        do: ["stage"],
        else: ["final", "review", "landed"]
      ) and
      Enum.map(greens, & &1.stage_id) == completed and
      Enum.reduce_while(evidence, 1, fn e, index ->
        if e.stage_index == index,
          do: {:cont, if(e.green, do: index + 1, else: index)},
          else: {:halt, false}
      end) == length(completed) + 1 and
      Enum.all?(evidence, fn e ->
        stage = Enum.at(plan, e.stage_index - 1)

        stage["id"] == e.stage_id and e.contract == b.approval_bytes and bound?(b, e) and
          is_binary(e.tree) and is_boolean(e.green) and
          (not e.green or
             (e.clean and e.moved == [] and e.failing == [] and e.not_run == [] and
                Enum.map(e.checks, & &1.command) == stage["checks"] and
                Enum.map(e.setup, & &1.command) == b.config.setup and
                Enum.all?(e.setup ++ e.checks, &(&1.status == 0))))
      end)
  end
end
