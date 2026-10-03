defmodule Kogen.Engine.Build.Result do
  @moduledoc false

  @enforce_keys [:status, :reason, :failure, :run_id, :run_dir, :landed_sha, :lines]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          status: :landed | :failed | :parked,
          reason: term(),
          failure: Kogen.Contracts.Failure.t() | nil,
          run_id: String.t(),
          run_dir: Path.t(),
          landed_sha: String.t() | nil,
          lines: [String.t()]
        }
end

defmodule Kogen.Engine.Build.Request do
  @moduledoc false

  @enforce_keys [
    :slug,
    :project_root,
    :origin,
    :base,
    :model,
    :effort,
    :runtime,
    :provider_mod,
    :provider_config,
    :credential_source
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          project_root: Path.t(),
          origin: Path.t(),
          base: String.t(),
          model: String.t(),
          effort: String.t(),
          runtime: Kogen.Engine.Runtime.t(),
          provider_mod: module(),
          provider_config: term(),
          credential_source: :kogen_owned | :codex_borrowed | :custom
        }
end

defmodule Kogen.Engine.Build.Prepared do
  @moduledoc false

  @enforce_keys [:request, :run, :approval, :approval_commit, :intent, :intent_text, :base_sha]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          request: Kogen.Engine.Build.Request.t(),
          run: Kogen.State.Run.t(),
          approval: Kogen.State.Approval.t(),
          approval_commit: String.t(),
          intent: Kogen.Contracts.Intent.t(),
          intent_text: String.t(),
          base_sha: String.t()
        }
end

defmodule Kogen.Engine.Build.Session do
  @moduledoc false

  @enforce_keys [
    :request,
    :approval,
    :approval_commit,
    :intent,
    :intent_text,
    :project,
    :run,
    :cycle,
    :state_root,
    :run_dir,
    :base_sha,
    :workdir,
    :process_env,
    :git_env
  ]
  defstruct [
    :request,
    :approval,
    :approval_commit,
    :intent,
    :intent_text,
    :project,
    :run,
    :cycle,
    :state_root,
    :run_dir,
    :base_sha,
    :workdir,
    :process_env,
    :git_env,
    :harness_opts,
    :pack,
    :plan,
    :last_harness,
    :failure,
    :failure_text,
    :landed_sha,
    :acceptance,
    :receipts,
    lines: []
  ]

  @type t :: %__MODULE__{
          request: Kogen.Engine.Build.Request.t(),
          approval: Kogen.State.Approval.t(),
          approval_commit: String.t(),
          intent: Kogen.Contracts.Intent.t(),
          intent_text: String.t(),
          project: Kogen.Contracts.Project.t(),
          run: Kogen.State.Run.t(),
          cycle: struct(),
          state_root: Path.t(),
          run_dir: Path.t(),
          base_sha: String.t(),
          workdir: Path.t(),
          process_env: %{String.t() => String.t()},
          git_env: %{String.t() => String.t()},
          harness_opts: Kogen.Harness.Opts.t() | nil,
          pack: Kogen.Harness.Pack.t() | nil,
          plan: Kogen.Harness.Plan.t() | nil,
          last_harness: Kogen.Harness.Result.t() | nil,
          failure: Kogen.Contracts.Failure.t() | nil,
          failure_text: String.t() | nil,
          landed_sha: String.t() | nil,
          acceptance: [Kogen.Checks.LedgerRow.t()] | nil,
          receipts: [Kogen.Contracts.Receipt.t()] | nil,
          lines: [String.t()]
        }
end
