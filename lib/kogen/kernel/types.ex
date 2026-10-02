defmodule Kogen.Kernel.Types.ApprovalPreview do
  @moduledoc false

  @enforce_keys [:approval, :intent, :project_root, :origin, :git_env]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          approval: Kogen.State.Approval.t(),
          intent: Kogen.Contracts.Intent.t(),
          project_root: Path.t(),
          origin: Path.t(),
          git_env: %{String.t() => String.t()}
        }
end

defmodule Kogen.Kernel.Types.IntentStatus do
  @moduledoc false

  @enforce_keys [:slug, :status, :run_id, :landed_sha]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          status: Kogen.State.status(),
          run_id: String.t() | nil,
          landed_sha: String.t() | nil
        }
end

defmodule Kogen.Kernel.Types.BuildResult do
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

defmodule Kogen.Kernel.CLI.Args do
  @moduledoc false

  defstruct [
    :command,
    :project,
    :origin,
    :base,
    :model,
    :effort,
    :by,
    positionals: [],
    yes: false,
    json: false
  ]

  @type t :: %__MODULE__{
          command: atom(),
          project: Path.t() | nil,
          origin: Path.t() | nil,
          base: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          by: String.t() | nil,
          positionals: [String.t()],
          yes: boolean(),
          json: boolean()
        }
end

defmodule Kogen.Kernel.Build.Request do
  @moduledoc false

  @enforce_keys [
    :slug,
    :project_root,
    :origin,
    :base,
    :model,
    :effort,
    :runtime,
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
          runtime: Kogen.Kernel.Runtime.t(),
          provider_config: Kogen.Provider.ChatGPT.Config.t(),
          credential_source: :kogen_owned | :codex_borrowed | :custom
        }
end

defmodule Kogen.Kernel.Build.Prepared do
  @moduledoc false

  @enforce_keys [:request, :run, :approval, :approval_commit, :intent, :intent_text, :base_sha]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          request: Kogen.Kernel.Build.Request.t(),
          run: Kogen.State.Run.t(),
          approval: Kogen.State.Approval.t(),
          approval_commit: String.t(),
          intent: Kogen.Contracts.Intent.t(),
          intent_text: String.t(),
          base_sha: String.t()
        }
end

defmodule Kogen.Kernel.Build.Session do
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
          request: Kogen.Kernel.Build.Request.t(),
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
