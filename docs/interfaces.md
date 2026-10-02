# Kogen P0 interfaces (authoritative)

This file is the contract between domains. Change it only through the integrator. Types refer to `Kogen.Contracts.*` structs unless stated. Paths are absolute strings. Only `Kogen.Kernel` reads HOME, env or cwd; everyone else receives explicit values.

## Dependency graph (Boundary, acyclic)
`contracts` ← every domain. `workspace` → proc. `state` → workspace. `checks` → proc, workspace, project. `harness` → proc, provider, project. `kernel` → all. `build` is pure (contracts only).

## Kogen.Proc
- `run([String.t()], opts) :: {:ok, ProcResult.t()} | {:error, :enoent | term()}`
  - `cd:` required
  - `env:` %{String => String}, merged onto an allowlist (PATH, HOME, LANG, LC_ALL, TERM, TMPDIR, USER, SHELL, MIX_HOME, HEX_HOME, MISE_*, GIT_*)
  - `timeout_ms:` default 120_000
  - `log_path:` optional
  - `stdin:` `nil` | `{:binary, iodata}` | `{:file, path}`
- A non-zero exit is `{:ok, %ProcResult{exit_status: n}}`, not an error. A timeout is `{:ok, %ProcResult{timed_out: true, exit_status: nil}}`.

## Kogen.Workspace (git through Kogen.Proc; every function takes explicit repo paths and a `git_env` map)
- `create(origin, base_sha, root, build_id, git_env) :: {:ok, %{path: String.t(), base_sha: String.t()}} | {:error, term()}`: clone --local from origin into `<root>/w/<build_id>` and check out `base_sha` detached. Seeds deps/_build from `seed_from` (opt) with `cp -c -R`.
- `insert_files(path, %{dest_rel_path => binary}) :: :ok`
- `tree_hash(path, git_env) :: {:ok, sha}`: includes untracked, non-ignored files; private index.
- `changed_paths(path, base_sha, git_env) :: {:ok, [rel_path]}`
- `commit(path, message, trailers :: [{key, value}], git_env) :: {:ok, sha}`: `git add -A` + `git commit`. Signing follows the user's config; tests disable it via git_env.
- `land(path, origin, branch, expected_old_sha, run_id, git_env) :: :ok | {:error, :base_moved | :ref_locked | :not_fast_forward | term()}`: push HEAD to `refs/kogen/incoming/<run_id>`, CAS `refs/heads/<branch>`, delete the temp ref. Requires HEAD's sole parent == expected_old_sha.
- `park(path, origin, run_id, git_env) :: :ok`: pushes HEAD to `refs/kogen/parked/<run_id>`.
- `destroy(path) :: :ok`
- Ref helpers (`repo`, `git_env` first):
  - `ref_read(repo, ref, git_env) :: {:ok, sha} | {:error, :missing}`
  - `ref_create(repo, ref, sha, git_env) :: :ok | {:error, :exists}`
  - `ref_update(repo, ref, new, old, git_env) :: :ok | {:error, :stale}`
  - `ref_delete(repo, ref, expected, git_env) :: :ok | {:error, :stale}`
  - `commit_tree_with_files(repo, %{rel_path => binary}, parents, message, git_env) :: {:ok, sha}`
  - `read_file_at(repo, rev, path, git_env) :: {:ok, binary} | {:error, :missing}`
  - `commit_message(repo, rev, git_env) :: {:ok, binary}`
  - `rev_parse(repo, rev, git_env) :: {:ok, sha} | {:error, :missing}`
  - `ancestor?(repo, a, b, git_env) :: boolean()`

## Kogen.Intent / Kogen.Project
- `Kogen.Intent.parse(path) :: {:ok, Intent.t()} | {:error, [%{line: pos_integer(), message: String.t()}]}`
- `Kogen.Intent.parse_binary(binary, path) :: same`
- `Kogen.Intent.lint(Intent.t()) :: [%{rule: atom(), message: String.t(), line: pos_integer() | nil}]`
- `Kogen.Intent.hash(binary) :: String.t()` (sha256 hex)
- `Kogen.Project.load(checkout_root) :: {:ok, Project.t()} | {:error, [%{line, message}]}`, reading `.kogen/project.yaml`
- Acceptance test files for an Intent `<slug>` live at `.kogen/acceptance/<slug>_test.exs` in the checkout, and are installed into the Candidate at `test/acceptance/<slug>_test.exs`.

## Kogen.Provider
- `Kogen.Provider.ChatGPT.config(auth_path) :: {:ok, %Kogen.Provider.ChatGPT.Config{}} | {:error, ProviderError.t()}`
- `respond(config, ModelRequest.t()) :: {:ok, ModelResponse.t()} | {:error, ProviderError.t()}` (the ProviderPort behaviour is `respond(term(), ModelRequest.t())`)
- `Kogen.Provider.Fake.config(fixture_paths)` with the same `respond/2`.
- `ModelResponse.raw_items` = the full ordered output items. The harness sends them back with `function_call_output` items `{type: "function_call_output", call_id, output}`.

## Kogen.Harness
- `context_pack(%Kogen.Harness.Opts{}, intent_text) :: {:ok, %Kogen.Harness.Pack{text, refs, usage}} | {:error, term()}`
- `plan(%Opts{}, pack, intent_text) :: {:ok, %Kogen.Harness.Plan{text, usage}} | {:error, term()}`
- `develop(%Opts{}, intent_text, plan | nil, resume :: nil | %{previous_items: list(), failure_text: String.t()}) :: {:ok, %Kogen.Harness.Result{outcome: :done | :gate_red | :gave_up, gate: map() | nil, items: list(), turns, usage, transcript_path}} | {:error, term()}`
- `review(%Opts{}, intent_text, diff, check_summary) :: {:ok, %Kogen.Harness.Review{verdict: :accept | :revise, findings: [String.t()], usage}} | {:error, term()}`
- `%Kogen.Harness.Opts{}` fields:
  - `workdir`, `run_dir`, `project`
  - `provider_mod`, `provider_config`
  - `proc_mod`
  - `models` (`%{builder: {"gpt-6-luna", "max"}, strong: {"gpt-6.1-sol", "high"}}`)
  - `limits` (`%{max_turns: 60, wall_ms: 1_800_000}`)

## Kogen.Checks
- `fix(workdir, Project.t(), run_dir) :: {:ok, [ProcResult]}`: safe formatters only.
- `run_all(workdir, Project.t(), run_dir, git_env) :: {:ok, %{tree: sha, receipts: [Receipt.t()], status: :pass | {:fail, [String.t()]}}} | {:error, Failure.t()}`: the tree is hashed before and after; a change is a Failure `:candidate`/`:tree_mutated`.
- `acceptance(workdir, Intent.t(), run_dir) :: {:ok, %{status: :pass | {:fail, [id]}, ledger: [map()]}} | {:error, Failure.t()}`: the formatter source is embedded in the module and written into run_dir, never into the Candidate.
- `red_on_base(base_workdir, Intent.t(), run_dir) :: :ok | {:error, Failure.t()}`
- `protected_violations(workdir, base_sha, manifest :: %{path => sha256}, git_env) :: {:ok, [path]}`
- `scope_violations(workdir, base_sha, Intent.t(), Project.t(), allowed_extra :: [path], git_env) :: {:ok, [path]}`

## Kogen.Build.Cycle (pure)
- `new(%{approval: Approval, repairs: 2}) :: state`
- `step(state, event) :: {state, [effect]}`
- Events: `{:stage_ok, stage, data}`, `{:stage_failed, stage, Failure.t()}`, `{:review, :accept | :revise, findings}`, `{:landed, sha}`, `{:base_moved}`.
- Effects:
  - `{:run, :context | :plan | :develop | :fix | :check | :review | :commit | :land, args}`
  - `{:record, map}`
  - `{:finish, :landed | :failed | :parked, reason}`

## Kogen.State
- `%Kogen.State.Approval{}`, as defined in T9's brief.
- Functions:
  - `approve(repo, Approval, git_env)`
  - `approval(repo, slug, git_env)`
  - `claim(repo, run_id, git_env) :: :ok | {:error, {:claimed, run_id}}`
  - `release(repo, run_id, git_env)`
  - `start_run(root, Approval) :: {:ok, %Kogen.State.Run{}}`
  - `record(Run, map) :: :ok`
  - `put_landing(Run, %{approval_commit, expected_parent, final_tree, candidate_commit}) :: :ok`
  - `load(root, run_id)`
  - `list(root)`
  - `status(repo, root, slug, branch, git_env) :: :draft | :approved | :building | :landed | :failed | :parked`
  - `reconcile(repo, root, Run, branch, git_env)`
- Run dir layout: `<root>/runs/<run_id>/run.json`, `events.jsonl`, `transcripts/`, `logs/`.

## Commit trailers (landing commit)
- `Kogen-Intent: <slug>`
- `Kogen-Run: <run_id>`
- `Kogen-Approval: <approval commit sha>`
- `Kogen-Receipt: <final tree sha>`
