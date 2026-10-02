defmodule Kogen.Checks do
  @moduledoc "Runs deterministic project verification and records its results."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Proc, Kogen.Workspace, Kogen.Project],
    exports: [LedgerRow]

  alias Kogen.Checks.Fixer
  alias Kogen.Checks.Ledger
  alias Kogen.Checks.LedgerRow
  alias Kogen.Checks.Runner
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project

  @type run_result ::
          {:ok,
           %{
             tree: String.t(),
             receipts: [Kogen.Contracts.Receipt.t()],
             status: :pass | {:fail, [String.t()]}
           }}
          | {:error, Failure.t()}

  @spec fix(Path.t(), Project.t(), Path.t()) :: {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def fix(workdir, project, run_dir), do: Fixer.run(workdir, project, run_dir)

  @spec run_all(Path.t(), Project.t(), Path.t(), %{String.t() => String.t()}) :: run_result()
  def run_all(workdir, project, run_dir, git_env),
    do: Runner.run_all(workdir, project, run_dir, git_env)

  @spec acceptance(Path.t(), Intent.t(), Path.t()) ::
          {:ok, %{status: :pass | {:fail, [String.t()]}, ledger: [LedgerRow.t()]}}
          | {:error, Failure.t()}
  def acceptance(workdir, intent, run_dir), do: Ledger.acceptance(workdir, intent, run_dir)

  @spec red_on_base(Path.t(), Intent.t(), Path.t()) :: :ok | {:error, Failure.t()}
  def red_on_base(workdir, intent, run_dir), do: Ledger.red_on_base(workdir, intent, run_dir)

  @spec protected_violations(
          Path.t(),
          String.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: {:ok, [String.t()]} | {:error, term()}
  def protected_violations(workdir, base_sha, manifest, git_env),
    do: Runner.protected_violations(workdir, base_sha, manifest, git_env)

  @spec scope_violations(
          Path.t(),
          String.t(),
          Intent.t(),
          Project.t(),
          [String.t()],
          %{String.t() => String.t()}
        ) :: {:ok, [String.t()]} | {:error, term()}
  def scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env),
    do: Runner.scope_violations(workdir, base_sha, intent, project, allowed_extra, git_env)
end
