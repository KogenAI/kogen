defmodule Kogen.Kernel.CLI.Runner do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProviderError
  alias Kogen.Kernel.CLI.Args
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Kernel.Types.BuildResult
  alias Kogen.Kernel.Types.IntentStatus

  @spec run(Args.t()) :: {non_neg_integer(), String.t()}
  def run(%Args{command: :version} = args), do: version(args)
  def run(%Args{command: :intent_check} = args), do: intent_check(args)
  def run(%Args{command: :approve} = args), do: approve(args)
  def run(%Args{command: :build} = args), do: build(args)
  def run(%Args{command: :status} = args), do: status(args)
  def run(%Args{command: :report} = args), do: report(args)
  def run(%Args{command: :reconcile} = args), do: reconcile(args)

  defp version(args) do
    case project_directory(args) do
      :ok -> {0, "kogen #{Kogen.Kernel.version()}\n"}
      {:error, reason} -> command_error(reason)
    end
  end

  defp intent_check(args) do
    with :ok <- project_directory(args),
         path = Path.expand(hd(args.positionals), args.project),
         {:ok, intent} <- Kogen.Kernel.intent_check(path) do
      {0, "intent #{intent.slug}: valid (sha256 #{intent.sha256})\n"}
    else
      {:error, {:parse, issues}} -> {2, format_issues("parse", issues)}
      {:error, {:lint, issues}} -> {2, format_issues("lint", issues)}
      {:error, reason} -> command_error(reason)
    end
  end

  defp approve(args) do
    with :ok <- project_directory(args),
         {:ok, preview} <-
           Kogen.Kernel.approval_preview(
             hd(args.positionals),
             args.project,
             args.origin,
             args.base,
             args.by
           ) do
      confirm_approval(preview, args.yes)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp confirm_approval(%ApprovalPreview{} = preview, true) do
    case Kogen.Kernel.approve(preview) do
      {:ok, sha} -> {0, approval_screen(preview) <> "approved: #{sha}\n"}
      {:error, reason} -> command_error(reason)
    end
  end

  defp confirm_approval(%ApprovalPreview{} = preview, false) do
    screen = approval_screen(preview)
    IO.write(screen)

    case tty_confirmation() do
      :yes ->
        case Kogen.Kernel.approve(preview) do
          {:ok, sha} -> {0, "approved: #{sha}\n"}
          {:error, reason} -> command_error(reason)
        end

      :no ->
        {1, "approval declined\n"}

      :unavailable ->
        {2, "approval requires a TTY; pass --yes to approve explicitly\n"}
    end
  end

  defp build(args) do
    with :ok <- project_directory(args),
         {:ok, %BuildResult{} = result} <-
           Kogen.Kernel.build(
             hd(args.positionals),
             args.project,
             args.origin,
             args.base,
             args.model,
             args.effort
           ) do
      render_build(result)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp render_build(%BuildResult{status: :landed} = result) do
    {0, format_build(result)}
  end

  defp render_build(%BuildResult{} = result) do
    code = failure_code(result.failure)
    repair = repair_guidance(result.failure)
    {code, format_build(result) <> repair}
  end

  defp format_build(%BuildResult{} = result) do
    lines = Enum.map_join(result.lines, "\n", & &1)
    "run: #{result.run_id}\n#{lines}\nrun dir: #{result.run_dir}\n"
  end

  defp status(args) do
    with :ok <- project_directory(args),
         {:ok, statuses} <- Kogen.Kernel.status(args.project, args.origin, args.base) do
      if args.json, do: {0, status_json(statuses)}, else: {0, status_text(statuses)}
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp report(args) do
    with :ok <- project_directory(args),
         {:ok, json} <-
           Kogen.Kernel.report(hd(args.positionals), args.project, args.origin, args.base) do
      {0, json <> "\n"}
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp reconcile(args) do
    with :ok <- project_directory(args),
         {:ok, result} <-
           Kogen.Kernel.reconcile(hd(args.positionals), args.project, args.origin, args.base) do
      {0, "reconcile: #{result}\n"}
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp status_text([]), do: "no Intents\n"

  defp status_text(statuses) do
    Enum.map_join(statuses, "", fn status ->
      "#{status.slug} #{status.status} run=#{value(status.run_id)} landed=#{value(status.landed_sha)}\n"
    end)
  end

  defp status_json(statuses) do
    rows = Enum.map(statuses, &status_row/1)
    rows |> :json.encode() |> IO.iodata_to_binary() |> Kernel.<>("\n")
  end

  defp status_row(%IntentStatus{} = status) do
    Map.new([
      {"slug", status.slug},
      {"status", Atom.to_string(status.status)},
      {"run_id", nullable(status.run_id)},
      {"landed_sha", nullable(status.landed_sha)}
    ])
  end

  defp approval_screen(preview) do
    intent = preview.intent
    criteria = Enum.map_join(intent.acceptance, "", &acceptance_line/1)

    """
    Intent: #{intent.slug} — #{intent.title}
    SHA-256: #{preview.approval.intent_sha256}
    Approved by: #{preview.approval.by}
    Base: #{preview.approval.target_branch} at #{preview.approval.base_sha}

    Brief
    #{indent(intent.brief)}

    Acceptance
    #{criteria}
    """
  end

  defp acceptance_line(item), do: "  - [#{item.id}] #{item.text} (#{item.verify})\n"

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp tty_confirmation do
    case File.open("/dev/tty", [:read, :write]) do
      {:ok, device} -> read_confirmation(device)
      {:error, _reason} -> :unavailable
    end
  end

  defp read_confirmation(device) do
    answer = IO.gets(device, "Approve this Intent? [y/N] ")
    File.close(device)
    if is_binary(answer) and String.downcase(String.trim(answer)) == "y", do: :yes, else: :no
  end

  defp format_issues(kind, issues) do
    rows = Enum.map_join(issues, "", &issue_line/1)
    "#{kind} failed:\n#{rows}"
  end

  defp issue_line(%{rule: rule, message: message, line: line}),
    do: "  #{rule} at #{line}: #{message}\n"

  defp issue_line(%{line: line, message: message}), do: "  line #{line}: #{message}\n"

  defp project_directory(%Args{project: project}) do
    if File.dir?(project), do: :ok, else: {:error, {:project_unavailable, project}}
  end

  defp command_error(%Failure{} = failure) do
    code = failure_code(failure)
    {code, "#{failure.class}/#{failure.reason}: #{failure.detail}\n"}
  end

  defp command_error(%ProviderError{class: class, message: message}),
    do: {4, "provider/#{class}: #{message}\n"}

  defp command_error(:mise_missing), do: {3, "environment/mise_missing: mise was not found\n"}

  defp command_error(:toolchain_failed),
    do: {3, "environment/toolchain_failed: mise env failed\n"}

  defp command_error(:invalid_toolchain_environment),
    do: {3, "environment/invalid_toolchain_environment: mise returned invalid JSON\n"}

  defp command_error({:script_path_unavailable, reason}),
    do: {3, "environment/script_path_unavailable: #{inspect(reason)}\n"}

  defp command_error(:too_many_script_symlinks),
    do: {3, "environment/too_many_script_symlinks: cannot resolve kogen path\n"}

  defp command_error(:intent_not_approved),
    do: {3, "environment/not_approved: Intent has no approval ref\n"}

  defp command_error(:approval_branch_mismatch),
    do: {3, "environment/approval_branch_mismatch: approval targets another branch\n"}

  defp command_error({:project_unavailable, project}),
    do: {3, "environment/project_unavailable: #{project}\n"}

  defp command_error({:base_moved, expected, current}) do
    {3, "environment/base_moved: expected #{expected}, found #{inspect(current)}\n"}
  end

  defp command_error(reason), do: {70, "controller/#{inspect(reason)}\n"}

  defp failure_code(%Failure{class: :candidate}), do: 1
  defp failure_code(%Failure{class: :environment}), do: 3
  defp failure_code(%Failure{class: :provider}), do: 4
  defp failure_code(%Failure{class: :controller}), do: 70
  defp failure_code(_failure), do: 70

  defp repair_guidance(%Failure{class: :candidate}),
    do: "repair: harness resumes with failure output (maximum 2 repairs)\n"

  defp repair_guidance(%Failure{class: :provider}),
    do: "repair: provider retry limit reached; check credentials or service availability\n"

  defp repair_guidance(_failure), do: ""

  defp value(nil), do: "-"
  defp value(value), do: value
  defp nullable(nil), do: :null
  defp nullable(value), do: value
end
