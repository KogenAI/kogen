defmodule Kogen.ShapingAudit do
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  @moduledoc """
  Deterministic audit of one Shaping Draft or Approved package.

  The audit reads a strict package snapshot, materializes `HEAD` in a private
  clone, runs the deterministic rules, and writes a schema version 1 report.
  """
  use Boundary,
    deps: [Kogen.Intent, Kogen.Harness, Kogen.Build, Kogen.VerificationPolicy, Kogen.Git]

  alias Kogen.ShapingAudit.{Deterministic, Finding, Materialization, Package, Questions, Report}

  @refused_roles ~w(developer reviewer expert auditor)
  @lock_path ".kogen/build.lock"
  @config_path ".kogen/config.yaml"

  @spec main([String.t()], keyword()) :: 0 | 1 | 2
  def main(args, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    env = normalize_env(Keyword.get(opts, :env, System.get_env()))
    io = Keyword.get(opts, :io, %{puts: &IO.puts/1, err: &IO.puts(:stderr, &1)})

    case parse_args(args) do
      {:ok, :status, route, slug} ->
        run_status(root, env, io, opts, route, slug)

      {:ok, :audit, route, slug} ->
        run_audit(root, env, io, opts, route, slug)

      :usage ->
        io.err.(usage())
        2
    end
  end

  defp normalize_env(env) when is_map(env), do: env
  defp normalize_env(env) when is_list(env), do: Map.new(env)
  defp normalize_env(_), do: %{}

  defp usage do
    "usage: mix kogen.audit [--route <name>] <slug> | mix kogen.audit --status [--route <name>] <slug>"
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [route: :string, status: :boolean]) do
      {opts, [slug], []} when slug != "" ->
        if Keyword.get(opts, :status, false),
          do: {:ok, :status, Keyword.get(opts, :route), slug},
          else: {:ok, :audit, Keyword.get(opts, :route), slug}

      _ ->
        :usage
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp run_status(root, env, io, opts, route, slug) do
    cond do
      refused_role?(env) ->
        refuse_role(io, env)

      File.exists?(Path.join(root, @lock_path)) ->
        refuse(io, "build lock is present")

      true ->
        read = Keyword.get(opts, :read, &File.read/1)

        with {:ok, package_rel} <- Package.locate(root, slug),
             {:ok, %{revision: revision}} <- Package.load(root, package_rel, read),
             {:ok, head} <- Kogen.Git.head_sha(root),
             {:ok, config} <- Kogen.Intent.read_config(Path.join(root, @config_path), route) do
          status = Report.status(root, slug, revision, head, config.route)
          status = prefer_route_staleness(status, route)
          print_status(io, status)
          if status == :current and report_ready?(root, slug, revision), do: 0, else: 1
        else
          {:error, {:non_regular, path}} -> refuse(io, "non-regular package entry: #{path}")
          {:error, {:ambiguous, message}} -> refuse(io, message)
          {:error, {:not_found, message}} -> refuse(io, message)
          {:error, reason} -> refuse(io, inspect(reason))
        end
    end
  end

  defp print_status(io, :current), do: io.puts.("current")
  defp print_status(io, {:stale, changed}), do: io.puts.("stale: #{Enum.join(changed, ", ")}")
  defp print_status(io, :missing), do: io.puts.("missing")

  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp run_audit(root, env, io, opts, route, slug) do
    cond do
      refused_role?(env) ->
        refuse_role(io, env)

      File.exists?(Path.join(root, @lock_path)) ->
        refuse(io, "build lock is present")

      true ->
        case audit(root, %{slug: slug, route: route, env: env, opts: opts}) do
          {:ok, report, _path} ->
            io.puts.("#{report["readiness"]}: #{report["revision"]}")
            if report["readiness"] == "ready", do: 0, else: 1

          {:error, {:non_regular, path}} ->
            refuse(io, "non-regular package entry: #{path}")

          {:error, {:ambiguous, message}} ->
            refuse(io, message)

          {:error, {:not_found, message}} ->
            refuse(io, message)

          {:error, reason} ->
            refuse(io, inspect(reason))
        end
    end
  end

  defp refused_role?(env), do: Map.get(env, "KOGEN_ROLE") in @refused_roles
  defp refuse_role(io, env), do: refuse(io, "refuses role #{inspect(Map.get(env, "KOGEN_ROLE"))}")
  defp refuse(io, message), do: io.err.("mix kogen.audit refuses: #{message}") && 2

  defp prefer_route_staleness({:stale, changed}, route) when is_binary(route) do
    if "route" in changed, do: {:stale, ["route"]}, else: {:stale, changed}
  end

  defp prefer_route_staleness(status, _route), do: status

  @doc "Runs one deterministic audit and writes its report."
  def audit(root, %{slug: slug} = params) do
    route = Map.get(params, :route)
    opts = Map.get(params, :opts, [])
    read = Keyword.get(opts, :read, &File.read/1)

    with {:ok, package_rel} <- Package.locate(root, slug),
         {:ok, %{files: files, revision: revision}} <- Package.load(root, package_rel, read),
         {:ok, head} <- Kogen.Git.head_sha(root),
         {:ok, config} <- Kogen.Intent.read_config(Path.join(root, @config_path), route),
         {:ok, materialization} <- Materialization.create(root, package_rel, files) do
      ctx = %{
        root: root,
        slug: slug,
        package_rel: package_rel,
        files: files,
        revision: revision,
        head: head,
        route: config.route,
        materialization: materialization.dir,
        intent: parse_yaml_map(files["intent.yaml"]),
        scenarios: parse_yaml_list(files["scenarios.yaml"]),
        questions: Questions.parse(files["questions.md"]),
        opts: opts
      }

      try do
        deterministic = Deterministic.run(ctx)

        findings =
          Finding.apply_dispositions(deterministic["findings"] || [], ctx.questions.dispositions)

        layer = Map.delete(deterministic, "findings")

        readiness =
          if deterministic["status"] == "ok" and
               Enum.all?(findings, fn finding -> not Finding.open_blocking?(finding) end),
             do: "ready",
             else: "not_ready"

        report = %{
          "slug" => slug,
          "package" => package_rel,
          "revision" => revision,
          "head" => head,
          "route" => config.route,
          "layers" => %{"deterministic" => layer},
          "findings" => findings,
          "readiness" => readiness
        }

        {:ok, path} = Report.write(root, slug, report)
        {:ok, report, path}
      after
        Materialization.remove(materialization)
      end
    end
  end

  defp parse_yaml_map(nil), do: nil

  defp parse_yaml_map(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, value} when is_map(value) -> value
      _ -> nil
    end
  end

  defp parse_yaml_list(nil), do: nil

  defp parse_yaml_list(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, value} when is_list(value) -> value
      _ -> nil
    end
  end

  defp report_ready?(root, slug, revision) do
    match?({:ok, %{"readiness" => "ready"}}, Report.read(root, slug, revision))
  end
end
