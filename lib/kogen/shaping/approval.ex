defmodule Kogen.Shaping.Approval do
  @moduledoc """
  Presentations and the approval transaction.

  A ready turn records a *presentation* (`p-<seq>-<first 12 hex of the
  revision>`) with an immutable proposal copy of the exact package bytes.
  `mix kogen.shape ID --approve PRESENTATION` approves only that current
  presentation, under the exclusive session lock, through a journal
  (`approvals/<id>.json`) whose phases are `staging` (a byte snapshot),
  `bookkept` (`approval.md` and the `approval:` map in `intent.yaml`),
  `audited` (the byte diff and a checkpoint audit of the bookkept
  revision), `renamed` and `done`. `recover_approval/1` completes or rolls
  back an interrupted transaction from the journal phase and the
  filesystem, never re-running bookkeeping blindly. Approval never starts a
  Build.
  """

  alias Kogen.Shaping.{Custody, Draft, Notifier, Store}
  alias Kogen.ShapingAudit.{Finding, Package, Report}

  @config_path ".kogen/config.yaml"
  @terminal ~w(done rolled_back)
  @commit_wait_ms 10_000
  @binding_keys ~w(id revision head route inputs_through)

  # --- presentations -------------------------------------------------------

  @doc """
  Records a presentation of the package's current bytes for a ready full
  report and returns `{:ok, session}`; `{:pending, session}` when an accepted
  input is not yet recorded in the Draft. The proposal copy is written from
  `Package.load` bytes and checked against the revision. When those bytes,
  HEAD or the session route are not exactly the report's revision, HEAD and
  route, nothing is presented: `{:stale, session}`.
  """
  def present!(root, dir, session, package, report, report_path) do
    observe(:before_presentation)
    present_uncontended(root, dir, session, package, {report, report_path})
  end

  # Under the commit lock a message takes to store its input: every input is
  # either already accepted here (and must be recorded, or nothing is
  # presented: `{:pending, session}`) or numbered after `inputs_through`,
  # which clears the presentation.
  defp present_uncontended(root, dir, session, package, {report, report_path}) do
    locked =
      Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
        {:ok, session} = Store.read_session(dir)
        {:ok, %{files: files, revision: revision}} = Draft.load(root, package)
        text = files["questions.md"]
        recorded = Store.recorded(dir, text)
        session = bind_configuration(root, dir, session)

        cond do
          not Kogen.Shaping.configuration_current?(root, session) ->
            {:stale, session}

          not Enum.all?(Store.messages(dir), &Map.has_key?(recorded, &1["id"])) ->
            {:pending, session}

          Draft.open_questions(text) != [] or
              not ready_report?(root, package.slug, revision, session["route"], report) ->
            {:stale, session}

          true ->
            present_current!(root, dir, session, package, report, report_path, files)
        end
      end)

    case locked do
      {:ok, result} -> result
      {:error, :busy} -> {:pending, session}
    end
  end

  defp bind_configuration(root, dir, session) do
    if session["config_fingerprint"] do
      session
    else
      case Kogen.Shaping.session_config(root, session) do
        {:ok, config} ->
          Store.write_session!(
            dir,
            Map.put(session, "config_fingerprint", Kogen.Shaping.config_fingerprint(config))
          )

        _ ->
          session
      end
    end
  end

  @doc """
  True when `report` is for exactly `revision`, `head` and `route` (the
  readiness rule's first condition).
  """
  def current_report?(revision, head, route, report) do
    is_map(report) and report["revision"] == revision and report["head"] == head and
      report["route"] == route
  end

  defp ready_report?(root, slug, revision, route, report) do
    current_report?(revision, head(root), route, report) and
      report["scope"] == "full" and report["readiness"] == "ready" and
      Report.status(root, slug, revision, head(root), route) == :current and
      match?(
        {:ok, %{"scope" => "full", "readiness" => "ready"}},
        Report.read(root, slug, revision)
      ) and
      not Enum.any?(report["findings"] || [], &(&1["rule"] == "answer-not-applied"))
  end

  defp present_current!(root, dir, session, package, report, report_path, files) do
    revision = report["revision"]
    seq = (session["presentation_seq"] || 0) + 1
    id = "p-#{seq}-#{binary_part(revision, 0, 12)}"
    proposal = Path.join([dir, "presentations", Integer.to_string(seq), "package"])
    File.rm_rf!(proposal)

    Enum.each(files, fn {relative, bytes} ->
      destination = Path.join(proposal, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, bytes)
    end)

    {:ok, %{revision: ^revision}} = Package.load(proposal, ".")

    through = Store.messages(dir) |> Enum.map(& &1["number"]) |> Enum.max(fn -> 0 end)

    presented = %{
      "id" => id,
      "seq" => seq,
      "slug" => package.slug,
      "revision" => revision,
      "head" => report["head"],
      "route" => report["route"],
      "report_json" => report_path,
      "report_md" => Path.join(Path.dirname(report_path), "report.md"),
      "presented_at" => Store.now(),
      "proposal_dir" => Path.relative_to(proposal, root),
      "inputs_through" => through
    }

    {:ok, session} = Store.read_session(dir)

    if ready_report?(root, package.slug, Draft.revision(root, package), session["route"], report) do
      Store.event!(dir, "presented", %{"presentation" => id, "revision" => revision})

      {:ok,
       Store.write_session!(
         dir,
         Map.merge(session, %{
           "state" => "ready",
           "error" => nil,
           "presented" => presented,
           "presentation_seq" => seq,
           "report" => report_path
         })
       )}
    else
      {:stale, session}
    end
  end

  # --- the approve command ---------------------------------------------------

  @doc "Runs `--approve` for session `id`; see the module doc."
  def approve(root, id, dir, opts, request) do
    presentation = opts.approve

    if Store.cancellation_busy?(dir) do
      {:refuse, "busy", "an accepted cancellation of session #{id} is unsettled", id}
    else
      case acquire_quietly(dir) do
        {:error, _reason} ->
          {:refuse, "busy",
           "a Shaping turn or another approval holds session #{id}; retry when it ends", id}

        {:ok, _acquired} ->
          approve_acquired(root, id, dir, presentation, opts, request)
      end
    end
  end

  defp acquire_quietly(dir), do: Kogen.Shaping.quietly(fn -> Custody.acquire(dir) end)

  defp approve_acquired(root, id, dir, presentation, opts, request) do
    retain_key = {__MODULE__, :retain_custody, make_ref()}

    result =
      try do
        recover_and_approve(root, id, dir, presentation, opts, request)
      rescue
        error ->
          settle_or_retain(root, dir, presentation, retain_key)
          reraise(error, __STACKTRACE__)
      catch
        kind, reason ->
          settle_or_retain(root, dir, presentation, retain_key)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        retain = Process.delete(retain_key)

        if retain !== true,
          do: Kogen.Shaping.quietly(fn -> Custody.release(dir) end)
      end

    Kogen.Shaping.wake_pending(root, id, dir)
    result
  end

  defp recover_and_approve(root, id, dir, presentation, opts, request) do
    if Store.cancellation_busy?(dir) do
      {:refuse, "busy", "an accepted cancellation of session #{id} is unsettled", id}
    else
      # A journal can remain recoverable after its lock was already
      # released (for example, a controller died just after the
      # audited phase). Recover under custody on every public retry,
      # not only when this process had to reclaim a stale lock.
      recover_approval(dir)
      approve_locked(root, id, dir, presentation, opts, request)
    end
  end

  defp approve_locked(root, id, dir, presentation, opts, request) do
    {:ok, session} = Store.read_session(dir)
    journal = read_journal(dir, presentation)
    presented = Kogen.Shaping.current_presentation(session, dir)

    cond do
      journal && journal["phase"] == "done" ->
        {:ok, journal["outcome"]}

      presented == nil or presented["id"] != presentation ->
        {:refuse, "presentation_superseded",
         "#{presentation} is not the current presentation of session #{id}" <>
           current_hint(presented), id}

      true ->
        with {:ok, package} <- draft_package(root, id),
             :ok <- no_open_work(root, dir, package),
             :ok <- no_prior_approval(root, package),
             :ok <- same_baseline(root, id, dir, session, package, presented),
             {:ok, _config} <- Kogen.Shaping.session_config(root, session),
             {:ok, report_path} <- final_audit(root, dir, session, package, presented) do
          transact(root, id, dir, session, package, presented, report_path, {opts, request})
        end
    end
  end

  defp current_hint(nil), do: "; nothing is presented"
  defp current_hint(presented), do: "; the current presentation is #{presented["id"]}"

  defp draft_package(root, id) do
    case Draft.locate(root, id) do
      {:ok, %{location: :drafts} = package} -> {:ok, package}
      _other -> {:refuse, "not_ready", "session #{id} has no Draft under drafts/", id}
    end
  end

  defp no_open_work(root, dir, package) do
    text = Draft.questions_text(root, package)
    recorded = Store.recorded(dir, text)
    unrecorded = Enum.reject(Store.messages(dir), &Map.has_key?(recorded, &1["id"]))

    cond do
      unrecorded != [] ->
        {:refuse, "not_ready", "unrecorded input: #{Enum.map_join(unrecorded, ", ", & &1["id"])}"}

      Draft.open_questions(text) != [] ->
        {:refuse, "not_ready", "## Ask the Shaper has an open entry"}

      true ->
        :ok
    end
  end

  defp no_prior_approval(root, package) do
    dir = Path.join(root, package.package_rel)

    approval? =
      File.exists?(Path.join(dir, "approval.md")) or
        match?(
          {:ok, %{"approval" => _}},
          YamlElixir.read_from_file(Path.join(dir, "intent.yaml"))
        )

    if approval?,
      do:
        {:refuse, "not_ready",
         "the Draft already carries approval metadata under drafts/; invalid state"},
      else: :ok
  end

  defp head(root) do
    case Kogen.Git.head_sha(root) do
      {:ok, head} -> head
      _error -> nil
    end
  end

  # Step 4: a changed revision, HEAD or route makes the presentation stale.
  defp same_baseline(root, id, dir, session, package, presented) do
    current = %{
      "revision" => Draft.revision(root, package),
      "head" => head(root),
      "route" => session["route"]
    }

    if current == Map.take(presented, ["revision", "head", "route"]) do
      :ok
    else
      Store.event!(dir, "presentation_stale", %{
        "presentation" => presented["id"],
        "current" => current
      })

      session = Store.write_session!(dir, Map.put(session, "presented", nil))
      reaudit(root, dir, session, package)

      {:refuse, "presentation_superseded",
       "#{presented["id"]} is stale (the Draft, HEAD or route changed); it was re-audited" <>
         current_hint(Kogen.Shaping.current_presentation(elem(Store.read_session(dir), 1), dir)),
       id}
    end
  end

  defp reaudit(root, dir, session, package) do
    case audit(root, session, %{slug: package.slug, auditor: true}) do
      {:ok, %{"readiness" => "ready", "scope" => "full"} = report, path} ->
        case present!(root, dir, session, package, report, path) do
          {:ok, session} -> Notifier.notify(dir, session, "ready", ready_body(session, package))
          {_stale_or_pending, session} -> reaudit_blocked(dir, session, package)
        end

      _other ->
        reaudit_blocked(dir, session, package)
    end
  end

  defp reaudit_blocked(dir, session, package) do
    session =
      Store.write_session!(dir, Map.merge(session, %{"state" => "blocked", "error" => nil}))

    Notifier.notify(
      dir,
      session,
      "blocked",
      "Kogen: #{package.slug} is blocked — mix kogen.shape #{session["intent_id"]}"
    )
  end

  @doc false
  def ready_body(session, package) do
    "Kogen: #{package.slug} is ready — mix kogen.shape #{session["intent_id"]} --approve #{session["presented"]["id"]}"
  end

  # Step 5: the final approval audit is a current full ready report for
  # exactly the presented revision, HEAD and route.
  defp final_audit(root, dir, session, package, presented) do
    %{"revision" => revision, "head" => head, "route" => route} = presented

    current? =
      Report.status(root, package.slug, revision, head, route) == :current and
        match?(
          {:ok, %{"scope" => "full", "readiness" => "ready"}},
          Report.read(root, package.slug, revision)
        )

    if current? do
      {:ok, Path.join(Report.dir(root, package.slug, revision), "report.json")}
    else
      case audit(root, session, %{slug: package.slug, auditor: true, reuse: true}) do
        {:ok,
         %{
           "readiness" => "ready",
           "scope" => "full",
           "revision" => ^revision,
           "head" => ^head,
           "route" => ^route
         }, path} ->
          {:ok, path}

        _other ->
          Store.update_session!(dir, &Map.put(&1, "presented", nil))
          {:refuse, "not_ready", "the final approval audit of #{revision} is not ready"}
      end
    end
  end

  defp audit(root, session, params) do
    case Kogen.Shaping.session_config(root, session) do
      {:ok, config} ->
        Kogen.Shaping.quietly(fn ->
          Kogen.ShapingAudit.audit(
            root,
            Map.merge(%{route: session["route"], env: System.get_env(), config: config}, params)
          )
        end)

      {:refuse, _code, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Steps 6-9.
  # The whole transaction is bound to the presented revision, HEAD, route
  # and input generation: the snapshot must be exactly the presented bytes,
  # the checkpoint audit must be of exactly the bookkept revision on the
  # presented HEAD and route, and the commit (`audited`, then the rename)
  # re-checks all of it under the commit lock, which a message holds while
  # it stores its input.
  defp transact(root, id, dir, session, package, presented, report_path, {opts, request}) do
    pid = presented["id"]
    package_dir = Path.join(root, package.package_rel)
    {:ok, %{files: files, revision: revision}} = Draft.load(root, package)

    if revision != presented["revision"] do
      {:refuse, "presentation_superseded",
       "the Draft changed after #{pid} was presented; nothing was approved", id}
    else
      snapshot = Path.join(dir, "approvals/#{pid}.snapshot")
      File.rm_rf!(snapshot)
      write_files!(snapshot, files)

      advance!(dir, pid, "staging", %{
        "snapshot" => Path.relative_to(snapshot, dir),
        "slug" => package.slug,
        "presented" => Map.take(presented, @binding_keys)
      })

      approval = approval_map(presented, opts, request)
      File.write!(Path.join(package_dir, "approval.md"), approval_markdown(id, approval))

      File.write!(
        Path.join(package_dir, "intent.yaml"),
        bookkept_intent(files["intent.yaml"], approval)
      )

      bookkept = Draft.revision(root, package)
      advance!(dir, pid, "bookkept", %{"revision" => bookkept})
      observe(:after_bookkept)

      with :ok <- bookkeeping_only(root, package, files, approval),
           :ok <- still_baseline(root, dir, presented),
           {:ok, checkpoint} <- checkpoint_clean(root, session, package, bookkept, presented),
           {:ok, result} <-
             commit(root, id, dir, package, presented, bookkept, %{
               "report" => report_path,
               "checkpoint" => checkpoint
             }) do
        result
      else
        {:refuse, code, message} ->
          rollback!(root, dir, pid)
          {:refuse, code, message, id}
      end
    end
  end

  # Step 9 under the commit lock: the bookkept bytes, HEAD, route and input
  # generation are still the approved ones, then `audited` and the rename.
  defp commit(root, id, dir, package, presented, bookkept, audited) do
    observe(:before_commit)

    locked =
      Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
        commit_locked(root, id, dir, package, presented, bookkept, audited)
      end)

    case locked do
      # A stale commit is rolled back by the caller.
      {:ok, {:refuse, _code, _message} = refusal} -> refusal
      # `rename/5` already rolled back (the approved/ target exists).
      {:ok, {:refuse, _code, _message, _id} = refusal} -> {:ok, refusal}
      {:ok, {:ok, _outcome} = result} -> {:ok, result}
      {:error, :busy} -> {:refuse, "busy", "a message held session #{id} during the commit"}
    end
  end

  defp commit_locked(root, id, dir, package, presented, bookkept, audited) do
    package_dir = Path.join(root, package.package_rel)

    with :ok <- no_pending_cancellation(dir),
         :ok <- fresh(root, dir, package_dir, presented, bookkept),
         :ok <- observe(:after_validation),
         :ok <- fresh(root, dir, package_dir, presented, bookkept) do
      advance!(dir, presented["id"], "audited", audited)
      rename(root, id, dir, package, presented["id"])
    end
  end

  defp no_pending_cancellation(dir) do
    if Store.cancellation_busy?(dir),
      do: {:refuse, "busy", "an accepted cancellation is unsettled"},
      else: :ok
  end

  # The package at `package_dir` is still exactly the bookkept revision, HEAD
  # and route are still the presented ones, and no input was accepted after
  # the presentation.
  defp fresh(root, dir, package_dir, presented, bookkept) do
    {:ok, session} = Store.read_session(dir)

    revision =
      case Package.load(package_dir, ".") do
        {:ok, %{revision: revision}} -> revision
        _other -> nil
      end

    newer = Enum.filter(Store.messages(dir), &(&1["number"] > (presented["inputs_through"] || 0)))

    cond do
      not Kogen.Shaping.configuration_current?(root, session) ->
        {:refuse, "configuration_changed",
         "the admitted role configuration changed during approval"}

      revision != bookkept ->
        {:refuse, "presentation_superseded", "the Draft changed during approval"}

      not same_head_and_route?(root, session, presented) ->
        {:refuse, "presentation_superseded", "HEAD or the route changed during approval"}

      newer != [] ->
        {:refuse, "presentation_superseded",
         "input #{Enum.map_join(newer, ", ", & &1["id"])} was accepted during approval"}

      true ->
        no_open_work(root, dir, %{package_rel: Path.relative_to(package_dir, root)})
    end
  end

  defp same_head_and_route?(root, session, presented),
    do: head(root) == presented["head"] and session["route"] == presented["route"]

  defp write_files!(dir, files) do
    Enum.each(files, fn {relative, bytes} ->
      destination = Path.join(dir, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, bytes)
    end)
  end

  defp approval_map(presented, opts, request) do
    %{
      "presentation" => presented["id"],
      "approved_revision" => presented["revision"],
      "approved_against_head" => presented["head"],
      "approved_at" => Store.now(),
      "route" => presented["route"],
      "interface" => Map.get(opts, :interface, "cli"),
      "request_id" => request["request_id"],
      "source" => "mix kogen.shape --approve",
      "authority" => "interface-attested"
    }
  end

  @approval_keys ~w(presentation approved_revision approved_against_head approved_at route interface request_id source authority)

  @doc false
  def bookkept_intent(original, approval) do
    base = if String.ends_with?(original, "\n"), do: original, else: original <> "\n"

    base <>
      "approval:\n" <>
      Enum.map_join(@approval_keys, "", fn key ->
        "  #{key}: #{Jason.encode!(approval[key])}\n"
      end)
  end

  defp approval_markdown(id, approval) do
    """
    # Approval

    Approved through `mix kogen.shape #{id} --approve #{approval["presentation"]}`.

    - presentation: `#{approval["presentation"]}`
    - approved revision: `#{approval["approved_revision"]}` (the revision the Shaper was shown)
    - approved against HEAD: `#{approval["approved_against_head"]}`
    - route: `#{approval["route"]}`
    - approved at: #{approval["approved_at"]}
    - interface: `#{approval["interface"]}`
    - request id: `#{approval["request_id"]}`
    - authority: `interface-attested` — the driving interface attests that the
      human approved; Kogen verified no human identity and no enforced
      authorization boundary exists.
    """
  end

  # Step 8: the bookkept revision differs from the presented one only by
  # approval.md and the approval map.
  defp bookkeeping_only(root, package, before, approval) do
    {:ok, %{files: now}} = Draft.load(root, package)
    expected_intent = bookkept_intent(before["intent.yaml"], approval)

    same_others =
      Map.drop(now, ["approval.md", "intent.yaml"]) == Map.drop(before, ["intent.yaml"]) and
        not Map.has_key?(before, "approval.md")

    if same_others and now["intent.yaml"] == expected_intent and is_binary(now["approval.md"]),
      do: :ok,
      else: {:refuse, "presentation_superseded", "the Draft changed during approval bookkeeping"}
  end

  defp still_baseline(root, dir, presented) do
    {:ok, session} = Store.read_session(dir)

    if Kogen.Shaping.configuration_current?(root, session) and
         head(root) == presented["head"] and session["route"] == presented["route"],
       do: :ok,
       else: {:refuse, "presentation_superseded", "HEAD or the route changed during approval"}
  end

  # The checkpoint audit counts only for exactly the bookkept revision on the
  # presented HEAD and route.
  defp checkpoint_clean(root, session, package, bookkept, presented) do
    case audit(root, session, %{slug: package.slug, scope: :checkpoint}) do
      {:ok, report, path} ->
        blocking = Enum.filter(report["findings"] || [], &Finding.open_blocking?/1)

        cond do
          report["revision"] != bookkept ->
            {:refuse, "presentation_superseded", "the Draft changed during the approval audit"}

          report["head"] != presented["head"] or report["route"] != presented["route"] ->
            {:refuse, "presentation_superseded",
             "HEAD or the route changed during the approval audit"}

          blocking != [] ->
            {:refuse, "not_ready",
             "the bookkept revision has blocking findings: #{Enum.map_join(blocking, ", ", & &1["id"])}"}

          true ->
            {:ok, path}
        end

      {:error, reason} ->
        {:refuse, "not_ready", "the bookkept revision could not be audited: #{inspect(reason)}"}
    end
  end

  defp rename(root, id, dir, package, pid) do
    target = Path.join([root, ".kogen/intents/approved", package.slug])

    if File.exists?(target) do
      rollback!(root, dir, pid)
      {:refuse, "not_ready", ".kogen/intents/approved/#{package.slug} already exists", id}
    else
      File.mkdir_p!(Path.dirname(target))
      File.rename!(Path.join(root, package.package_rel), target)
      observe(:after_rename)
      advance!(dir, pid, "renamed", %{"approved" => Path.relative_to(target, root)})
      complete!(root, dir, pid)
      {:ok, read_journal(dir, pid)["outcome"]}
    end
  end

  defp complete!(root, dir, pid) do
    session =
      Store.update_session!(dir, &Map.merge(&1, %{"state" => "approved", "error" => nil}))

    unless Enum.any?(Store.events(dir), fn event ->
             event["event"] == "approved" and event["presentation"] == pid
           end) do
      Store.event!(dir, "approved", %{"presentation" => pid})
    end

    # The journal is about to become `done`; the recorded outcome reports it so.
    outcome =
      root
      |> Kogen.Shaping.status(session["intent_id"])
      |> Map.put("state", "approved")
      |> Map.put("approval", %{"presentation" => pid, "phase" => "done", "status" => "approved"})

    advance!(dir, pid, "done", %{"outcome" => outcome})
  end

  # --- recovery ------------------------------------------------------------------

  @doc """
  Completes or rolls back every interrupted approval of the session in
  `dir`. Runs while holding exclusive session custody after reclaiming a dead
  holder. A handled failure settles only its current transaction in place.
  """
  def recover_approval(dir) do
    root = dir |> Path.join("../../../..") |> Path.expand()

    for journal <- journals(dir), journal["phase"] not in @terminal do
      recover(root, dir, journal)
    end

    :ok
  end

  defp recover(root, dir, %{"presentation" => pid, "phase" => phase, "slug" => slug} = journal) do
    draft = Path.join([root, ".kogen/intents/drafts", slug])
    approved = Path.join([root, ".kogen/intents/approved", slug])
    carries? = carries_presentation?(approved, journal)

    cond do
      carries? ->
        unless phase == "renamed",
          do:
            advance!(dir, pid, "renamed", %{
              "approved" => Path.relative_to(approved, root),
              "recovered" => true
            })

        complete!(root, dir, pid)

      phase == "audited" and File.dir?(draft) and not File.exists?(approved) ->
        recover_audited(root, dir, journal, draft, approved)

      true ->
        rollback!(root, dir, pid)
    end
  end

  defp recover(_root, _dir, _journal), do: :ok

  # Settles only this transaction under its existing custody. Session-wide
  # recovery remains reserved for a reclaimed dead owner.
  defp settle_or_retain(root, dir, pid, retain_key) do
    settle_current(root, dir, pid)
  rescue
    _error -> Process.put(retain_key, true)
  catch
    _kind, _reason -> Process.put(retain_key, true)
  end

  defp settle_current(root, dir, pid) do
    case read_journal(dir, pid) do
      %{"phase" => phase} = journal when phase not in @terminal ->
        recover(root, dir, journal)

      _other ->
        :ok
    end
  end

  # An audited approval is finished only while the Draft is still exactly
  # the bookkept revision on the presented HEAD and route with no newer
  # input, checked and renamed under the commit lock; otherwise (or for a
  # journal without its presented binding) it rolls back.
  defp recover_audited(root, dir, %{"presentation" => pid} = journal, draft, approved) do
    presented = journal["presented"]

    finished =
      is_map(presented) and
        match?(
          {:ok, :renamed},
          Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
            if not Store.cancellation_busy?(dir) and
                 fresh(root, dir, draft, presented, journal["revision"]) == :ok do
              File.mkdir_p!(Path.dirname(approved))
              File.rename!(draft, approved)

              advance!(dir, pid, "renamed", %{
                "approved" => Path.relative_to(approved, root),
                "recovered" => true
              })

              :renamed
            end
          end)
        )

    if finished, do: complete!(root, dir, pid), else: rollback!(root, dir, pid)
  end

  @doc """
  True once an approval of the session in `dir` has committed (renamed the
  package to approved/); the session takes no further input.
  """
  def committed?(dir) do
    root = dir |> Path.join("../../../..") |> Path.expand()

    match?({:ok, %{"state" => "approved"}}, Store.read_session(dir)) or
      Enum.any?(journals(dir), fn journal ->
        # A crash between the rename and its journal write leaves the package
        # already under approved/ while the journal still says `audited`.
        journal["phase"] in ["renamed", "done"] or
          (journal["phase"] not in @terminal and is_binary(journal["slug"]) and
             carries_presentation?(
               Path.join([root, ".kogen/intents/approved", journal["slug"]]),
               journal
             ))
      end)
  end

  @doc false
  def recovery_pending?(dir),
    do: Enum.any?(journals(dir), &(&1["phase"] not in @terminal))

  defp carries_presentation?(approved, journal) do
    binding = journal["presented"] || %{}

    with {:ok, %{revision: revision, files: files}} <- Package.load(approved, "."),
         true <- revision == journal["revision"],
         {:ok, %{"approval" => approval}} <- YamlElixir.read_from_string(files["intent.yaml"]) do
      approval["presentation"] == journal["presentation"] and
        approval["approved_revision"] == binding["revision"] and
        approval["approved_against_head"] == binding["head"] and
        approval["route"] == binding["route"] and
        approval["authority"] == "interface-attested"
    else
      _ -> false
    end
  end

  # Process-local observation lets crash/race tests pause the actual transaction
  # without adding a command flag or a persistent runtime setting.
  defp observe(phase) do
    case Process.get({__MODULE__, :observer}) do
      fun when is_function(fun, 1) -> fun.(phase)
      _ -> :ok
    end
  end

  # Restores the snapshot bytes exactly (approval.md removed), verifies the
  # revision equals the presented one, and marks `approval_rolled_back`.
  # The presentation stays, so `--approve` can be retried.
  defp rollback!(root, dir, pid) do
    journal = read_journal(dir, pid)
    slug = journal["slug"]
    package_dir = Path.join([root, ".kogen/intents/drafts", slug])
    snapshot = Path.join(dir, journal["snapshot"] || "approvals/#{pid}.snapshot")

    if File.dir?(snapshot) and File.dir?(package_dir) do
      {:ok, %{files: saved}} = Package.load(snapshot, ".")
      {:ok, %{files: current}} = Package.load(package_dir, ".")
      Enum.each(Map.keys(current) -- Map.keys(saved), &File.rm!(Path.join(package_dir, &1)))
      write_files!(package_dir, saved)
    end

    {:ok, session} = Store.read_session(dir)

    restored =
      case Package.load(package_dir, ".") do
        {:ok, %{revision: revision}} -> revision
        _ -> nil
      end

    verified = restored == get_in(journal, ["presented", "revision"])
    pending = Store.unrecorded_messages(dir, File.read!(Path.join(package_dir, "questions.md")))
    advance!(dir, pid, "rolled_back", %{"restored_revision" => restored, "verified" => verified})

    Store.write_session!(
      dir,
      Map.merge(session, %{
        "state" => if(pending == [], do: "failed", else: "running"),
        "error" => %{
          "code" => "approval_rolled_back",
          "message" =>
            "approval #{pid} was rolled back; the Draft bytes were restored (verified: #{verified})"
        }
      })
    )

    Store.event!(dir, "approval_rolled_back", %{"presentation" => pid, "verified" => verified})
  end

  # --- journal -------------------------------------------------------------------

  defp journal_path(dir, pid), do: Path.join([dir, "approvals", pid <> ".json"])

  @doc "The approval journal of presentation `pid`, or nil."
  def read_journal(dir, pid) do
    case Store.read_json(journal_path(dir, pid)) do
      {:ok, journal} -> journal
      _ -> nil
    end
  end

  defp journals(dir) do
    dir
    |> Path.join("approvals/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Store.read_json(path) do
        {:ok, journal} -> [journal]
        _ -> []
      end
    end)
  end

  defp advance!(dir, pid, phase, extra) do
    journal = read_journal(dir, pid) || %{"presentation" => pid, "history" => []}
    entry = %{"phase" => phase, "at" => Store.now()}

    updated =
      journal
      |> Map.merge(extra)
      |> Map.put("phase", phase)
      |> Map.update("history", [entry], &(&1 ++ [entry]))

    Store.write_json!(journal_path(dir, pid), updated)
    updated
  end

  @doc """
  The approval status for `mix kogen.shape ID`: the latest journal's
  presentation and phase (`approval_in_progress` while not terminal).
  """
  def journal_status(dir) do
    dir
    |> journals()
    |> Enum.max_by(&(get_in(&1, ["history", Access.at(-1), "at"]) || ""), fn -> nil end)
    |> case do
      nil ->
        nil

      journal ->
        status =
          case journal["phase"] do
            "done" -> "approved"
            "rolled_back" -> "rolled_back"
            _ -> "approval_in_progress"
          end

        %{
          "presentation" => journal["presentation"],
          "phase" => journal["phase"],
          "status" => status
        }
    end
  end

  @doc false
  def config_path, do: @config_path
end
