defmodule CodegenTestHarness.InterruptedCycleRecovery do
  @moduledoc """
  Recovers one interrupted `building/` claim without losing dirty work or
  guessing lifecycle ownership.
  """

  alias CodegenTestHarness.{LoopQueue, OrchestrationLoop}

  @type recovery ::
          :none
          | {:resume, String.t()}
          | {:requeued, String.t(), :clean | {:parked, String.t()}}
  @type park_error :: %{location: String.t(), reason: String.t()}

  @journal_keys ~w(branch original_ref slug stage transaction_id updated_at)
  @parking_stages ~w(parking parked history_written resume_pending)

  @spec reconcile(keyword()) :: {:ok, recovery()} | {:error, String.t()}
  def reconcile(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    building_dir = Keyword.get(opts, :building_dir, pitches_dir(cwd, "building"))
    ready_dir = Keyword.get(opts, :ready_dir, pitches_dir(cwd, "ready"))
    journal = Keyword.get(opts, :journal_path, journal_path(cwd))
    roles = Keyword.fetch!(opts, :roles)

    with {:ok, claims} <- building_claims(building_dir),
         journal_result <- read_journal(journal),
         {:ok, result} <- reconcile_claims(claims, cwd, ready_dir, journal, journal_result, roles, opts) do
      {:ok, result}
    end
  end

  @spec park_worktree(String.t(), String.t(), String.t(), :strict | :warning) ::
          {:ok, :clean | {:parked, String.t()}} | {:error, park_error()}
  def park_worktree(cwd, slug, namespace, policy) when policy in [:strict, :warning] do
    transaction_id = "#{namespace}:#{slug}:#{utc_stamp()}-#{System.unique_integer([:positive])}"
    park_worktree(cwd, slug, namespace, policy, transaction_id)
  end

  @doc false
  @spec complete_resume_claim!(String.t(), String.t()) :: :ok
  def complete_resume_claim!(cwd, slug) do
    path = journal_path(cwd)

    case read_journal(path) do
      {:ok, %{"slug" => ^slug, "stage" => "resume_pending"}} ->
        File.rm!(path)
        :ok

      :absent ->
        :ok

      {:ok, _journal} ->
        raise "InterruptedCycleRecovery: resume journal does not belong to #{slug}"

      {:error, reason} ->
        raise "InterruptedCycleRecovery: invalid resume journal: #{reason}"
    end
  end

  defp reconcile_claims([], _cwd, _ready_dir, _journal, :absent, _roles, _opts), do: {:ok, :none}

  defp reconcile_claims([], cwd, ready_dir, journal_path, {:ok, journal}, roles, opts) do
    ready_claim = Path.join(ready_dir, "#{journal["slug"]}.md")

    with :ok <- validate_journal(journal),
         "resume_pending" <- journal["stage"],
         true <- File.exists?(ready_claim) do
      resume_pending(journal, ready_claim, cwd, ready_dir, journal_path, roles, opts)
    else
      false ->
        {:error,
         "interrupted recovery journal #{journal_path} has no ready claim at #{ready_claim} for #{inspect(journal["slug"])}"}

      :error ->
        {:error, "interrupted recovery journal #{journal_path}: malformed journal fields"}

      _ ->
        {:error,
         "interrupted recovery journal #{journal_path} has no matching building claim for #{inspect(journal["slug"])}"}
    end
  end
  defp reconcile_claims([], _cwd, _ready_dir, journal_path, {:error, reason}, _roles, _opts) do
    {:error, "interrupted recovery journal #{journal_path}: #{inspect(reason)}"}
  end

  defp reconcile_claims([claim], cwd, ready_dir, path, journal_result, roles, opts) do
    slug = Path.basename(claim, ".md")

    case journal_result do
      :absent -> reconcile_new_claim(claim, slug, cwd, ready_dir, path, roles, opts)
      {:ok, journal} -> resume_transaction(journal, claim, cwd, ready_dir, path, roles, opts)
      {:error, reason} ->
        {:error, "interrupted recovery journal #{path}: #{inspect(reason)}"}
    end
  end

  defp reconcile_claims(claims, _cwd, _ready_dir, _journal, _journal_result, _roles, _opts) do
    names = claims |> Enum.map(&Path.basename/1) |> Enum.join(", ")
    {:error, "interrupted recovery refused: multiple building pitches: #{names}"}
  end

  defp reconcile_new_claim(claim, slug, cwd, ready_dir, path, roles, opts) do
    checkpoint_opts = opts |> Keyword.put(:slug, slug) |> Keyword.put(:cwd, cwd)

    case OrchestrationLoop.resume_checkpoint(cwd, roles, checkpoint_opts) do
      {:resume, _role, _state} ->
        journal = new_journal(slug, "", original_ref!(cwd), "resume_pending")
        write_journal!(path, journal)
        move_to_ready!(claim, ready_dir)
        {:ok, {:resume, slug}}

      :full ->
        claim_body = File.read!(claim)
        journal = new_journal(slug, "", original_ref!(cwd), "parking")
        write_journal!(path, journal)

        case park_worktree(cwd, slug, "recovery/interrupted", :strict, journal["transaction_id"]) do
          {:ok, result} ->
            branch = result_branch(result)
            parked = %{journal | "branch" => branch, "stage" => "parked", "updated_at" => now()}
            write_journal!(path, parked)
            restored_claim = Path.join(ready_dir, Path.basename(claim))
            File.mkdir_p!(ready_dir)
            File.write!(restored_claim, claim_body)
            write_history!(restored_claim, parked, result)

            history_written = %{parked | "stage" => "history_written", "updated_at" => now()}
            write_journal!(path, history_written)
            finish_requeue!(claim, ready_dir, cwd, path)
            {:ok, {:requeued, slug, result}}

          {:error, %{location: location, reason: reason}} ->
            {:error, "interrupted recovery could not park #{location}: #{reason}"}
        end
    end
  end

  defp adopt_parking_transaction(cwd, journal) do
    transaction_id = journal["transaction_id"]

    with {:ok, branches} <- transaction_branches(cwd, transaction_id),
         {:ok, stashes} <- transaction_stashes(cwd, transaction_id) do
      case {branches, stashes} do
        {[branch], []} ->
          with {:ok, _} <- git(cwd, ["checkout", journal["original_ref"]]) do
            {:ok, branch}
          end

        {[], [stash]} ->
          branch = "recovery/interrupted/#{journal["slug"]}/#{utc_stamp()}"

          with :ok <- ensure_branch_absent(cwd, branch),
               {:ok, _} <- git(cwd, ["stash", "branch", branch, stash]),
               {:ok, _} <- git(cwd, ["add", "-A"]),
               {:ok, _} <-
                 git(cwd, [
                   "commit",
                   "--allow-empty",
                   "-m",
                   "#{transaction_id} parked WIP from #{journal["original_ref"]}"
                 ]),
               {:ok, _} <- git(cwd, ["checkout", journal["original_ref"]]) do
            {:ok, branch}
          end

        {[], []} ->
          {:error, "parking transaction #{transaction_id} has no matching stash or branch"}

        _ ->
          {:error, "parking transaction #{transaction_id} has ambiguous matching stash or branch"}
      end
    end
  end

  defp transaction_branches(cwd, transaction_id) do
    with {:ok, output} <- git(cwd, ["for-each-ref", "--format=%(refname:short)%00%(contents:subject)", "refs/heads"] ) do
      branches =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn entry ->
          case String.split(entry, <<0>>, parts: 2) do
            [branch, subject] when is_binary(subject) ->
              if String.contains?(subject, transaction_id), do: [branch], else: []

            _ ->
              []
          end
        end)

      {:ok, branches}
    end
  end

  defp transaction_stashes(cwd, transaction_id) do
    with {:ok, output} <- git(cwd, ["stash", "list", "--format=%gd%x00%s"]) do
      stashes =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn entry ->
          case String.split(entry, <<0>>, parts: 2) do
            [stash, subject] when is_binary(subject) ->
              if String.contains?(subject, transaction_id), do: [stash], else: []

            _ ->
              []
          end
        end)

      {:ok, stashes}
    end
  end

  defp resume_pending(journal, claim, cwd, ready_dir, path, roles, opts) do
    slug = journal["slug"]
    checkpoint_opts = opts |> Keyword.put(:cwd, cwd) |> Keyword.put(:slug, slug)

    case OrchestrationLoop.resume_checkpoint(cwd, roles, checkpoint_opts) do
      {:resume, _role, _state} ->
        ready_claim = Path.join(ready_dir, Path.basename(claim))

        if claim != ready_claim do
          move_to_ready!(claim, ready_dir)
        end

        {:ok, {:resume, slug}}

      :full ->
        # The checkpoint was valid when recovery first moved the claim back
        # to ready, but is no longer resumable (most importantly: its tree is
        # now clean because the recovered bytes already landed). Leaving the
        # resume_pending journal in place makes every later startup fail on
        # the same stale decision. Retire the checkpoint transaction and
        # return the claim to the ordinary full-run lane without touching
        # HEAD; any already-landed descendant commit remains intact.
        finish_requeue!(claim, ready_dir, cwd, path)
        {:ok, {:requeued, slug, :clean}}
    end
  end

  defp resume_parking(journal, claim, cwd, ready_dir, path) do
    claim_body = File.read!(claim)

    with {:ok, branch} <- adopt_parking_transaction(cwd, journal),
         :ok <- verify_parked_branch(cwd, %{journal | "branch" => branch}) do
      restored_claim = Path.join(ready_dir, Path.basename(claim))
      File.mkdir_p!(ready_dir)

      history_claim =
        cond do
          File.exists?(claim) -> claim
          File.exists?(restored_claim) -> restored_claim
          true ->
            File.write!(restored_claim, claim_body)
            restored_claim
        end

      parked = %{journal | "branch" => branch, "stage" => "parked", "updated_at" => now()}
      write_journal!(path, parked)
      write_history!(history_claim, parked, {:parked, branch})
      write_journal!(path, %{parked | "stage" => "history_written", "updated_at" => now()})
      finish_requeue!(claim, ready_dir, cwd, path)
      {:ok, {:requeued, journal["slug"], {:parked, branch}}}
    else
      {:error, reason} -> {:error, "interrupted recovery journal #{path}: #{reason}"}
    end
  end

  defp resume_transaction(journal, claim, cwd, ready_dir, path, roles, opts) do
    with :ok <- validate_journal(journal),
         slug <- Map.fetch!(journal, "slug"),
         ^slug <- Path.basename(claim, ".md") do
      case journal["stage"] do
        "resume_pending" ->
          resume_pending(journal, claim, cwd, ready_dir, path, roles, opts)

        "parking" ->
          resume_parking(journal, claim, cwd, ready_dir, path)

        "parked" ->
          verify_parked_branch(cwd, journal)
          write_history!(claim, journal, {:parked, journal["branch"]})
          write_journal!(path, %{journal | "stage" => "history_written", "updated_at" => now()})
          finish_requeue!(claim, ready_dir, cwd, path)
          {:ok, {:requeued, slug, {:parked, journal["branch"]}}}

        "history_written" ->
          verify_parked_branch(cwd, journal)
          finish_requeue!(claim, ready_dir, cwd, path)
          {:ok, {:requeued, slug, {:parked, journal["branch"]}}}

        stage ->
          {:error, "interrupted recovery journal #{path}: unknown stage #{inspect(stage)}"}
      end
    else
      :error -> {:error, "interrupted recovery journal #{path} belongs to another building claim"}
      {:error, reason} -> {:error, "interrupted recovery journal #{path}: #{reason}"}
    end
  end

  defp finish_requeue!(claim, ready_dir, cwd, path) do
    ready_claim = Path.join(ready_dir, Path.basename(claim))

    cond do
      claim == ready_claim and File.exists?(ready_claim) -> :ok
      File.exists?(ready_claim) and File.exists?(claim) -> File.rm!(claim)
      File.exists?(claim) -> move_to_ready!(claim, ready_dir)
      File.exists?(ready_claim) -> :ok
      true -> raise "InterruptedCycleRecovery: missing claim #{claim} during requeue"
    end

    clear_checkpoint!(cwd)
    File.rm!(path)
  end

  defp park_worktree(cwd, slug, namespace, _policy, transaction_id) do
    with {:ok, status} <- git(cwd, ["status", "--porcelain", "--untracked-files=all"]),
         {:dirty, _status} <- {:dirty, status},
         {:ok, original_ref} <- original_ref(cwd),
         branch = "#{namespace}/#{slug}/#{utc_stamp()}",
         :ok <- ensure_branch_absent(cwd, branch),
         {:ok, _} <- git(cwd, ["stash", "push", "--include-untracked", "-m", transaction_id]),
         {:ok, _} <- git(cwd, ["stash", "branch", branch, "stash@{0}"]),
         {:ok, _} <- git(cwd, ["add", "-A"]),
         {:ok, _} <-
           git(cwd, [
             "commit",
             "--allow-empty",
             "-m",
             "#{transaction_id} parked WIP from #{original_ref}"
           ]),
         {:ok, _} <- git(cwd, ["checkout", original_ref]) do
      {:ok, {:parked, branch}}
    else
      {:dirty, ""} -> {:ok, :clean}
      {:error, reason} -> {:error, %{location: cwd, reason: reason}}
    end
  end

  defp building_claims(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        claims =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.sort()

        {:ok, claims}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot read building directory #{dir}: #{inspect(reason)}"}
    end
  end

  defp validate_journal(journal) when is_map(journal) do
    if Map.keys(journal) |> Enum.sort() == @journal_keys and
         is_binary(journal["transaction_id"]) and journal["transaction_id"] != "" and
         is_binary(journal["slug"]) and journal["slug"] != "" and
         is_binary(journal["branch"]) and is_binary(journal["original_ref"]) and
         journal["original_ref"] != "" and journal["stage"] in @parking_stages and
         is_binary(journal["updated_at"]) and journal["updated_at"] != "" do
      :ok
    else
      {:error, "malformed journal fields"}
    end
  end

  defp validate_journal(_), do: {:error, "malformed JSON object"}

  defp verify_parked_branch(_cwd, %{"branch" => ""}), do: :ok

  defp verify_parked_branch(cwd, %{"branch" => branch, "transaction_id" => transaction_id}) do
    with {:ok, message} <- git(cwd, ["log", "-1", "--format=%B", branch]),
         true <- String.contains?(message, transaction_id) do
      :ok
    else
      false -> {:error, "parked branch #{branch} lacks transaction identity"}
      {:error, reason} -> {:error, "cannot verify parked branch #{branch}: #{reason}"}
    end
  end

  defp write_history!(claim, journal, result) do
    branch = result_branch(result)
    recovery = if branch == "", do: "none (tree clean)", else: branch

    row =
      "| interrupted recovery | #{utc_stamp()} | unaccountable | checkpoint=#{journal["stage"]}; recovery=#{recovery}; next=planner-inspection-required |"

    LoopQueue.write_history_row!(claim, "Build failure history", row)
  end

  defp read_journal(path) do
    case File.read(path) do
      {:error, :enoent} -> :absent
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, journal} -> {:ok, journal}
          {:error, _reason} -> {:error, "malformed JSON"}
        end

      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp write_journal!(path, journal) do
    File.mkdir_p!(Path.dirname(path))

    temporary =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}"
      )

    File.write!(temporary, Jason.encode!(journal))
    File.rename!(temporary, path)
  end

  defp clear_checkpoint!(cwd) do
    pending = Path.join([cwd, "codegen", "gate-pending"])

    for name <- ["gate-result.json", "cycle-state.json"] do
      case File.rm(Path.join(pending, name)) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          raise "InterruptedCycleRecovery: cannot remove #{name}: #{inspect(reason)}"
      end
    end
  end

  defp move_to_ready!(claim, ready_dir) do
    File.mkdir_p!(ready_dir)
    File.rename!(claim, Path.join(ready_dir, Path.basename(claim)))
  end

  defp ensure_branch_absent(cwd, branch) do
    case git(cwd, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {:ok, _} -> {:error, "recovery branch already exists: #{branch}"}
      {:error, _} -> :ok
    end
  end

  defp original_ref!(cwd) do
    case original_ref(cwd) do
      {:ok, ref} -> ref
      {:error, reason} -> raise "InterruptedCycleRecovery: cannot resolve original ref: #{reason}"
    end
  end

  defp original_ref(cwd) do
    case git(cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, ""} -> git(cwd, ["rev-parse", "HEAD"])
      {:ok, ref} -> {:ok, ref}
      {:error, _} -> git(cwd, ["rev-parse", "HEAD"])
    end
  end

  defp git(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp new_journal(slug, branch, original_ref, stage) do
    %{
      "branch" => branch,
      "original_ref" => original_ref,
      "slug" => slug,
      "stage" => stage,
      "transaction_id" =>
        "interrupted-recovery-#{utc_stamp()}-#{System.unique_integer([:positive])}",
      "updated_at" => now()
    }
  end

  defp result_branch(:clean), do: ""
  defp result_branch({:parked, branch}), do: branch
  defp pitches_dir(cwd, state), do: Path.join([cwd, "codegen", "pitches", state])

  defp journal_path(cwd),
    do: Path.join([cwd, "codegen", "gate-pending", "interrupted-recovery.json"])

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp utc_stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
end
