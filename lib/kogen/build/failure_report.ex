# credo:disable-for-this-file Credo.Check.Design.AliasUsage
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Kogen.Build.FailureReport do
  @moduledoc "Durable, one-per-build summaries for terminal Build failures."

  alias Kogen.Build.FailureSignature

  @schema_version 1

  @categories %{
    "verification-exhausted" => {"item", "rebuild"},
    "offline-exhausted" => {"item", "rebuild"},
    "unchanged-candidate" => {"item", "rebuild"},
    "outer-allowance-exhausted" => {"item", "rebuild"},
    "guard-violation" => {"item", "rebuild"},
    "protected-path" => {"item", "rebuild"},
    "git-policy" => {"item", "rebuild"},
    "integrity" => {"item", "rebuild"},
    "review-failure" => {"item", "rebuild"},
    "cannot-comply" => {"shaping", "reshape_scope"},
    "environment" => {"environment", "environment"},
    "provider-failure" => {"environment", "environment"},
    "write-boundary" => {"environment", "environment"},
    "admission" => {"environment", "environment"},
    "publication-failed" => {"environment", "environment"},
    "accepted-unpublished" => {"environment", "inspect"},
    "provider" => {"provider", "provider_wait"}
  }

  def report_path(control, build_id) when is_binary(control) and is_binary(build_id) do
    Path.join([
      Path.expand(control),
      ".kogen/runtime/scenario-tracking",
      build_id,
      "failure-report.json"
    ])
  end

  def classify(category), do: Map.get(@categories, category, {"item", "rebuild"})

  def counts_toward(category) do
    case classify(category) do
      {"item", _} -> "item"
      {"shaping", _} -> "item"
      {"environment", _} -> "environment"
      {"provider", _} -> nil
    end
  end

  @doc "Writes a report atomically and never replaces an existing report."
  def write(control, build_id, report)
      when is_binary(control) and is_binary(build_id) and is_map(report) do
    path = report_path(control, build_id)
    directory = Path.dirname(path)
    :ok = File.mkdir_p(directory)

    bytes =
      report
      |> Map.put_new("schema_version", @schema_version)
      |> Jason.encode_to_iodata!(pretty: true)

    temporary = Path.join(directory, ".failure-report-#{System.unique_integer([:positive])}.tmp")

    with {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io) do
      case :file.make_link(String.to_charlist(temporary), String.to_charlist(path)) do
        :ok ->
          File.rm(temporary)
          {:ok, path}

        {:error, :eexist} ->
          File.rm(temporary)
          {:ok, path}

        {:error, reason} ->
          File.rm(temporary)
          {:error, "could not publish failure report #{path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "could not write failure report #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Builds and persists one report from the latest controller context."
  def record_failure(ctx, category, reason, details \\ %{}) do
    tracking = ctx[:tracking] || %{}
    record = tracking[:record] || %{}
    build_id = tracking[:path] |> to_string() |> Path.dirname() |> Path.basename()
    control = ctx[:control] || File.cwd!()
    {class, default_action} = classify(category)
    attempt = List.last(record["attempts"] || []) || %{}

    signature =
      details["signature"] || List.last(attempt["failure_signatures"] || []) ||
        get_in(details, ["unchanged_candidate", "signature"]) ||
        List.last(attempt["cycle_signatures"] || []) ||
        FailureSignature.for_stop(category, reason)

    same_count = same_signature_count(control, record, signature)

    next_action =
      if class == "item" and same_count >= 2, do: "reshape_details", else: default_action

    next_command = details["next_command"] || login_command_from_reason(reason)
    intent = record["intent"] || %{}

    report = %{
      "schema_version" => @schema_version,
      "build_id" => build_id,
      "candidate_build_id" => get_in(ctx, [:candidate, :build_id]),
      "slug" => intent["slug"] || ctx[:slug],
      "intent_id" => intent["id"] || ctx[:intent_id] || get_in(ctx, [:intent, :id]),
      "approved_package_digest" => record["approved_package_digest"],
      "stopped_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "category" => category,
      "stop_class" => details["stop_class"] || attempt["stop_class"],
      "class" => class,
      "counts_toward" => counts_toward(category),
      "signature" => signature,
      "same_signature_count" => same_count,
      "next_action" => next_action,
      "next_command" => next_command,
      "developer_session_id" =>
        details["developer_session_id"] || attempt["developer_session_id"],
      "reason" => reason |> to_string() |> String.slice(0, 2_000),
      "candidate" => candidate_block(ctx),
      "record" => Path.relative_to(Path.expand(tracking[:path]), Path.expand(control)),
      "record_sha256" => record_sha(tracking)
    }

    write(control, build_id, report)
  rescue
    _ -> {:error, "failure report could not be constructed"}
  end

  defp record_sha(%{bytes: bytes}) when is_binary(bytes),
    do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp record_sha(_), do: nil

  defp candidate_block(%{candidate: nil}), do: nil

  defp candidate_block(%{candidate: candidate}) when is_map(candidate) do
    %{
      "worktree" => candidate.path,
      "branch" => candidate.branch,
      "harness_home" => candidate.harness_home,
      "owner_record" => candidate.owner_path
    }
  end

  defp candidate_block(_), do: nil

  defp same_signature_count(control, record, signature) do
    digest = signature["digest"]
    intent_id = get_in(record, ["intent", "id"])
    package_digest = record["approved_package_digest"]

    if is_binary(digest) do
      existing =
        Path.wildcard(
          Path.join([
            Path.expand(control),
            ".kogen/runtime/scenario-tracking/*/failure-report.json"
          ])
        )
        |> Enum.count(fn path ->
          with {:ok, bytes} <- File.read(path),
               {:ok, report} <- Jason.decode(bytes),
               true <- report["intent_id"] == intent_id,
               true <- report["approved_package_digest"] == package_digest,
               %{"digest" => ^digest} <- report["signature"] do
            true
          else
            _ -> false
          end
        end)

      existing + 1
    else
      1
    end
  end

  defp login_command_from_reason(reason) do
    case Regex.run(~r/Run (mix kogen\.[a-z]+\.login(?: --project)?)/, to_string(reason)) do
      [_, command] -> command
      _ -> nil
    end
  end
end
