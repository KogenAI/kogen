defmodule Kogen.Preflight do
  @moduledoc "Point-in-time read-only observations, not Build authorization."
  alias Kogen.{Config, Intent, Build, Git, Error, Bridge}

  def run(r) do
    Process.put(:kogen_read_only_git, true)
    root = r["project"]

    try do
      config = Config.load!(root)
      slug = r["slug"]

      package =
        check("package", fn ->
          case Intent.check(root, slug) do
            {:ok, _, _} ->
              :ok

            {_, problems} ->
              Error.raise!("intent", "invalid_package", Enum.join(problems, "; "), 1, [
                Intent.intent_md(slug),
                Intent.feature(slug)
              ])
          end
        end)

      checks = [
        check("configuration", fn -> :ok end),
        package,
        check("approval", fn ->
          approval =
            case File.read(Intent.approval_path(root, slug)) do
              {:ok, text} ->
                case JSON.decode(text) do
                  {:ok, a} when is_map(a) -> a
                  _ -> nil
                end

              _ ->
                nil
            end

          unless approval &&
                   approval["sha256"] == Intent.hash(root, Intent.baseline(root, slug, config)),
                 do:
                   Error.raise!(
                     "intent",
                     "approval_changed",
                     "exact current approval is absent or changed",
                     1,
                     [Intent.approval_path(root, slug)]
                   )
        end),
        if(Intent.exists?(root, slug),
          do: check("cleanliness", fn -> Build.clean_paths!(root, slug) end),
          else: %{name: "cleanliness", status: "not_evaluated", blockers: []}
        ),
        check("conflict", fn ->
          if op = Git.operation_in_progress(root),
            do: Error.raise!("environment", "git_operation_in_progress", op, 1)

          if Kogen.Lock.held?(Path.join(root, ".kogen/local/build.lock")),
            do: Error.raise!("environment", "build_running", "a Build owns this checkout", 1)
        end)
      ]

      blockers = Enum.flat_map(checks, & &1.blockers)

      data = %{
        slug: slug,
        ready: blockers == [],
        checks: Enum.map(checks, &Map.drop(&1, [:blockers])),
        blockers: blockers,
        limitations: [
          "Setup, checks, hooks, providers, tool availability, signing and full readiness/resume safety were not executed or established. Build revalidates normally."
        ]
      }

      output(r, data, nil)
      if blockers == [], do: 0, else: 1
    rescue
      e in Error ->
        output(r, nil, %{class: e.class, reason: e.reason, detail: e.detail, paths: e.lines})
        3
    end
  end

  defp check(name, fun) do
    try do
      fun.()
      %{name: name, status: "passed", blockers: []}
    rescue
      e in Error ->
        %{
          name: name,
          status: "blocked",
          blockers: [%{class: e.class, reason: e.reason, detail: e.detail, paths: e.lines}]
        }
    end
  end

  defp output(r, data, error) do
    if r["json"] do
      Bridge.puts(
        JSON.encode!(%{
          schema_version: 1,
          kind: "preflight",
          checkout: r["checkout"],
          data: data,
          error: error
        })
      )
    else
      Bridge.puts(
        if data,
          do:
            "preflight #{r["slug"]}: #{if data.ready, do: "ready (observations only)", else: "blocked"}",
          else: "preflight: #{error.detail}"
      )

      if data do
        for check <- data.checks, do: Bridge.puts("  #{check.name}: #{check.status}")

        for blocker <- data.blockers do
          Bridge.puts("  #{blocker.class}/#{blocker.reason}: #{blocker.detail}")
          for path <- blocker.paths, do: Bridge.puts("    #{path}")
        end

        for limitation <- data.limitations, do: Bridge.puts("  #{limitation}")
      end
    end
  end
end
