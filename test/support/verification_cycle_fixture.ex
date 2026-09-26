Code.require_file("fake_jev.ex", __DIR__)

defmodule Kogen.VerificationCycleFixture do
  @moduledoc """
  A minimal git-backed repository that exercises
  `Kogen.Build.Verification.initialize/6` and `run_cycle/4` directly, without
  going through a full scripted Build.

  The catalog declares three targets: an offline `check` (rank 0, no
  dependencies) and two provider-backed targets, `a` (rank 100) and `b` (rank
  200), both depending on `check`. Each Make recipe appends its own name to a
  gitignored counter file so a test can observe exactly which targets ran in
  a cycle. `b` fails while a gitignored marker file exists, and passes once
  it is removed; because both files are gitignored, toggling them never
  changes the Candidate id.
  """

  alias Kogen.Build.VerificationPlan
  alias Kogen.FakeJev

  @counter "target-calls.log"
  @marker "b-fail-marker"
  @harness_root Path.expand("../..", __DIR__)
  @harness_slug "verification-cycle-harness"
  @harness_selector "test/kogen/verification_harness_selector_test.exs"

  @doc "Creates a fresh fixture repository and returns its absolute root path."
  def new! do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-verification-cycle-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "priv/kogen"))
    File.write!(Path.join(root, "Makefile"), makefile())
    File.write!(Path.join(root, "priv/kogen/verification_targets.yaml"), catalog_bytes())
    File.write!(Path.join(root, ".gitignore"), "#{@counter}\n#{@marker}\n.kogen/\n")
    File.write!(Path.join(root, "tracked.txt"), "original\n")

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(root, "deps"))

    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["config", "user.name", "Fixture"])
    git!(root, ["config", "user.email", "fixture@example.invalid"])
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-qm", "baseline"])

    root
  end

  @doc "Marks the fixture so target `b` fails until `clear_b_failure!/1`."
  def fail_b!(root), do: File.write!(marker_path(root), "fail\n")

  @doc "Clears the marker so target `b` passes again."
  def clear_b_failure!(root), do: File.rm(marker_path(root))

  @doc "Edits a tracked file so the Candidate id changes."
  def edit_tracked_file!(root) do
    File.write!(Path.join(root, "tracked.txt"), "changed-#{System.unique_integer([:positive])}\n")
  end

  @doc """
  The ordered list of target names that ran, oldest first. Make recipes
  append to `target-calls.log` under `$KOGEN_LIVE_LOG_DIR` (the controller
  sets it to control's `.kogen/runtime/live-evidence` for every target
  child unless the caller already set one), so this survives a Candidate's
  removal at publication; it is read from control here.
  """
  def calls(root) do
    case File.read(counter_path(root)) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  @doc "Removes the counter so the next cycle's calls can be observed alone."
  def reset_calls!(root), do: File.rm(counter_path(root))

  @doc "The Candidate id (private-index write-tree) of `root`."
  def candidate_id!(root) do
    {:ok, id} = File.cd!(root, fn -> Kogen.Git.candidate_id() end)
    id
  end

  @doc "An `env` for `Kogen.Build.Verification.run_cycle/4` bound to `root`."
  def env(root, plan) do
    {:ok, catalog} = VerificationPlan.load(root)

    %{
      root: root,
      control_root: root,
      catalog: catalog,
      plan: plan,
      scenarios: plan.scenarios,
      base_commit: nil,
      candidate_id: fn -> File.cd!(root, fn -> Kogen.Git.candidate_id() end) end
    }
  end

  @doc "A hand-built plan selecting `check` and one of `a`/`b` (or both)."
  def plan(root, targets) do
    {:ok, catalog} = VerificationPlan.load(root)

    scenarios =
      for target <- targets, target != "check" do
        %{
          "id" => "sc-#{target}",
          "verified_by" => Enum.uniq(["check", target]),
          "proof" => %{"paid_target" => target}
        }
      end

    %{
      targets: Enum.uniq(targets),
      added: [],
      scenarios: scenarios,
      catalog_sha256: catalog.sha256
    }
  end

  @doc "A fresh `.kogen/runtime/scenario-tracking/<build>/...` tracking path."
  def tracking_path(root, build_id \\ "verification-cycle-build") do
    Path.join([root, ".kogen/runtime/scenario-tracking", build_id, "tracking.json"])
  end

  @doc "The admission catalog (`Kogen.Build.VerificationPlan.load/1`) of `root`."
  def catalog!(root) do
    {:ok, catalog} = VerificationPlan.load(root)
    catalog
  end

  @doc "An offline (no dependencies, not provider-backed) catalog entry map."
  def offline_entry(name, rank \\ 0) do
    %{
      "name" => name,
      "cost_class" => "offline",
      "rank" => rank,
      "dependencies" => [],
      "provider_backed" => false,
      "owner" => "fixture"
    }
  end

  @doc "A valid provider-backed catalog entry map, complete with a rehearsal block."
  def provider_entry(name, rank, deps \\ ["check"]), do: rehearsed_target(name, rank, deps)

  @doc """
  A structurally invalid provider-backed catalog entry (no `rehearsal`), used
  to exercise an invalid added target.
  """
  def invalid_provider_entry(name, rank, deps \\ ["check"]) do
    %{
      "name" => name,
      "cost_class" => "provider",
      "rank" => rank,
      "dependencies" => deps,
      "provider_backed" => true,
      "owner" => "fixture"
    }
  end

  @doc "Overwrites the Candidate's catalog file (not committed) with `entries`."
  def write_catalog!(root, entries) do
    File.write!(
      Path.join(root, "priv/kogen/verification_targets.yaml"),
      Jason.encode!(%{"targets" => entries})
    )
  end

  @doc "Overwrites the Candidate's Makefile (not committed) with a recipe per name in `names`."
  def write_makefile!(root, names) do
    File.write!(Path.join(root, "Makefile"), makefile_for(names))
  end

  @doc "Both `write_catalog!/2` and `write_makefile!/2` for the same target names."
  def write_catalog_and_makefile!(root, entries) do
    write_catalog!(root, entries)
    write_makefile!(root, Enum.map(entries, & &1["name"]))
  end

  defp marker_path(root), do: Path.join(root, @marker)

  defp counter_path(root),
    do: Path.join([root, ".kogen", "runtime", "live-evidence", @counter])

  # Appends to `target-calls.log` under `$KOGEN_LIVE_LOG_DIR` (falling back
  # to the recipe's own cwd, so direct-env tests with no controller-set
  # variable still work) instead of the `make` root, which is the Candidate
  # under a full `Kogen.Build.run/1` and is deleted at publication.
  defp append_call(name),
    do:
      "\t@dir=\"$${KOGEN_LIVE_LOG_DIR:-.}\"; mkdir -p \"$$dir\"; echo #{name} >> \"$$dir/#{@counter}\""

  defp makefile_for(names) do
    Enum.map_join(names, "\n", fn
      "b" ->
        "b:\n#{append_call("b")}\n\t@test ! -f #{@marker}"

      name ->
        "#{name}:\n#{append_call(name)}"
    end) <> "\n"
  end

  defp makefile do
    """
    .PHONY: check a b

    check:
    #{append_call("check")}

    a:
    #{append_call("a")}

    b:
    #{append_call("b")}
    \t@test ! -f #{@marker}
    """
  end

  defp catalog_bytes do
    Jason.encode!(%{
      "targets" => [
        %{
          "name" => "check",
          "cost_class" => "offline",
          "rank" => 0,
          "dependencies" => [],
          "provider_backed" => false,
          "owner" => "fixture"
        },
        rehearsed_target("a", 100, ["check"]),
        rehearsed_target("b", 200, ["check"])
      ]
    })
  end

  defp rehearsed_target(name, rank, deps) do
    %{
      "name" => name,
      "cost_class" => "provider",
      "rank" => rank,
      "dependencies" => deps,
      "provider_backed" => true,
      "owner" => "fixture",
      "rehearsal" => %{
        "id" => "rehearse-#{name}",
        "command" => "true",
        "shared_entrypoints" => ["#{name}.entrypoint"],
        "correct_fixture" => "#{name}-correct",
        "wrong_fixture" => "#{name}-wrong",
        "trace_assertions" => ["#{name}-trace"]
      }
    }
  end

  defp git!(root, args) do
    {_out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end

  # -- full-harness `Kogen.Build.run/1` fixtures ---------------------------
  #
  # A disposable project driven through the real `Kogen.Build.run/1` with a
  # scripted Codex-protocol fake provider (modeled on
  # `Kogen.ScriptedBuildFixture`), whose catalog carries a `check` (offline)
  # and a `paid` (provider-backed) target so catalog-change scenarios (a
  # declared added target, a selected target removed and restored) can be
  # driven end to end, asserting the same Developer session is resumed, the
  # attempt count and the Build reaching Review.

  @doc """
  Builds a disposable project for `run_full_harness/2`. `opts`:
    * `:paid_at_admission` - whether `paid` exists in the admission catalog
      and Makefile (default `false`)
    * `:declared_add` - whether `intent.yaml` declares `catalog_changes.add:
      [paid]` (default `false`)
    * `:outer_resumptions` - defaults to `3`
  """
  def harness_project!(opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-verification-harness-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    for path <- [
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          ".codex/hooks.json",
          "priv/kogen/prompts/execution-policy.md",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md"
        ] do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@harness_root, path), target)
    end

    File.chmod!(Path.join(dir, ".codex/hooks/check.sh"), 0o755)
    File.write!(Path.join(dir, "provider.py"), harness_provider())
    File.chmod!(Path.join(dir, "provider.py"), 0o755)
    File.write!(Path.join(dir, "harness-edit-tool.py"), harness_edit_tool())

    paid_at_admission = Keyword.get(opts, :paid_at_admission, false)
    declared_add = Keyword.get(opts, :declared_add, false)
    outer_resumptions = Keyword.get(opts, :outer_resumptions, 3)

    entries =
      [offline_entry("check")] ++
        if(paid_at_admission, do: [harness_paid_entry()], else: [])

    File.mkdir_p!(Path.join(dir, "priv/kogen"))

    File.write!(
      Path.join(dir, "priv/kogen/verification_targets.yaml"),
      Jason.encode!(%{"targets" => entries})
    )

    File.write!(Path.join(dir, "Makefile"), harness_makefile(Enum.map(entries, & &1["name"])))

    File.write!(
      Path.join(dir, ".gitignore"),
      ".kogen/build.lock\n.kogen/runtime/\n.kogen/intents/approved/\n"
    )

    File.mkdir_p!(Path.join(dir, ".kogen"))
    File.write!(Path.join(dir, ".kogen/config.yaml"), harness_config(outer_resumptions))

    selector_path = Path.join(dir, @harness_selector)
    File.mkdir_p!(Path.dirname(selector_path))
    File.write!(selector_path, "# verification harness selector fixture\n")
    File.write!(Path.join(dir, "dummy.txt"), "baseline\n")

    intent_dir = Path.join(dir, ".kogen/intents/approved/#{@harness_slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), harness_intent(declared_add))
    File.write!(Path.join(intent_dir, "scenarios.yaml"), Jason.encode!([harness_scenario()]))

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dir, "deps"))

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.name", "Fixture"])
    git!(dir, ["config", "user.email", "fixture@example.invalid"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", "baseline"])
    dir
  end

  @doc """
  Runs the harness project through `Kogen.Build.run/1`. `opts`:
    * `:edits` - `%{call => shell command}` run on the Developer's fresh
      turn `call` (1-based), before the Stop hook check
    * `:resume_edits` - `%{call => shell command}` run on the controller's
      verification-failure resume of the same Developer turn `call`
  """
  def run_full_harness(dir, opts \\ []) do
    runtime = Path.join(dir, ".kogen/runtime")

    env =
      [
        {"KOGEN_HARNESS", Path.join(dir, "provider.py")},
        {"HANDOFF_RESPONSE_HELPER",
         Path.join(@harness_root, "test/support/scenario_response.py")},
        {"FAKE_JEV_LOG_DIR", Path.join(runtime, "fake-jev")},
        {"FAKE_JEV_ANSWERS", Jason.encode!(%{})},
        {"FAKE_JEV_RESPONSES", nil},
        {"FAKE_SECURITY_ITEM", "present"},
        {"KOGEN_JEV_TRANSPORT", FakeJev.transport_path()},
        {"KOGEN_JEV_SECURITY", FakeJev.security_path()}
      ] ++
        Enum.map(Keyword.get(opts, :edits, %{}), fn {call, command} ->
          {"HARNESS_EDIT_#{call}", command}
        end) ++
        Enum.map(Keyword.get(opts, :resume_edits, %{}), fn {call, command} ->
          {"HARNESS_RESUME_EDIT_#{call}", command}
        end)

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    previous_raw = System.get_env("KOGEN_RAW_LOG_DIR")
    System.delete_env("KOGEN_RAW_LOG_DIR")

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      File.cd!(dir, fn -> Kogen.Build.run(@harness_slug, nil, dir) end)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if previous_raw, do: System.put_env("KOGEN_RAW_LOG_DIR", previous_raw)
    end
  end

  @doc "The harness project's tracking record."
  def harness_record!(dir) do
    [path] = Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))
    path |> File.read!() |> Jason.decode!()
  end

  @doc """
  The ordered list of every retained `verification-resume-<n>` prompt. The
  fake harness provider writes its scratch state (including these prompts)
  under the Build's harness home, since publication removes the Candidate
  where a plain `.kogen/runtime` relative write would otherwise land.
  """
  def harness_resume_prompts(dir) do
    Kogen.CandidateFixture.fake_state(dir)
    |> Path.join("verification-resume-*")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&File.read!/1)
  end

  @doc "The repository-relative offline selector path the `paid` rehearsal cites."
  def harness_selector, do: @harness_selector

  @doc "The shell command that adds (or restores) the `paid` target to the Candidate."
  def harness_add_paid_command, do: "python3 harness-edit-tool.py add #{@harness_selector}"

  @doc "The shell command that removes the `paid` target from the Candidate."
  def harness_remove_paid_command, do: "python3 harness-edit-tool.py remove"

  defp harness_paid_entry do
    %{
      "name" => "paid",
      "cost_class" => "provider",
      "rank" => 100,
      "dependencies" => ["check"],
      "provider_backed" => true,
      "owner" => "fixture",
      "rehearsal" => %{
        "id" => "rehearse-paid",
        "command" => "mix test --exclude live #{@harness_selector}",
        "shared_entrypoints" => ["paid.entrypoint"],
        "correct_fixture" => "paid-correct",
        "wrong_fixture" => "paid-wrong",
        "trace_assertions" => ["paid-trace"]
      }
    }
  end

  defp harness_makefile(names), do: Enum.map_join(names, "\n", &"#{&1}:\n\t@true") <> "\n"

  defp harness_config(outer_resumptions) do
    """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping:   {model: fake, effort: low}
        developer: {model: fake, effort: low}
        reviewer:  {model: fake, effort: low}
        helpers:
          scout:  {model: fake, effort: low}
          worker: {model: fake, effort: medium}
          expert: {model: fake, effort: medium}
    outer_resumptions: #{outer_resumptions}
    verification_retries: 2
    """
  end

  defp harness_intent(declared_add) do
    base = """
    id: 01960000-0000-7000-8000-0000000cade1
    slug: #{@harness_slug}
    title: Verification cycle harness fixture
    may_change_guarded_paths: [dummy.txt, Makefile, priv/kogen/verification_targets.yaml, test/**]
    """

    if declared_add, do: base <> "catalog_changes:\n  add: [paid]\n", else: base
  end

  defp harness_scenario do
    %{
      "id" => "s-paid",
      "given" => "a fixture Candidate",
      "when" => "Build settles the Developer turn",
      "then" => "both check and paid run and the Build reaches Review",
      "wrong_result" => "the paid target never runs",
      "verified_by" => ["check", "paid"],
      "evidence" => "fixture harness",
      "proof" => %{
        "offline" => [@harness_selector],
        "paid_target" => "paid",
        "paid_reason" =>
          "provider-required: paid; observation: fixture harness Build; offline-limit: fixture cannot substitute",
        "affected_paths" => [@harness_selector]
      }
    }
  end

  # Adds or removes the `paid` catalog entry and Makefile target as one
  # idempotent, shell-safe step the Developer's fake turn can invoke.
  defp harness_edit_tool do
    ~S'''
    #!/usr/bin/env python3
    import json, re, sys
    action = sys.argv[1]
    catalog_path = "priv/kogen/verification_targets.yaml"
    makefile_path = "Makefile"

    def add_paid(selector):
        data = json.load(open(catalog_path))
        if not any(t["name"] == "paid" for t in data["targets"]):
            data["targets"].append({
                "name": "paid", "cost_class": "provider", "rank": 100,
                "dependencies": ["check"], "provider_backed": True, "owner": "fixture",
                "rehearsal": {
                    "id": "rehearse-paid",
                    "command": "mix test --exclude live " + selector,
                    "shared_entrypoints": ["paid.entrypoint"],
                    "correct_fixture": "paid-correct", "wrong_fixture": "paid-wrong",
                    "trace_assertions": ["paid-trace"]
                }
            })
            json.dump(data, open(catalog_path, "w"))
        text = open(makefile_path).read()
        if not re.search(r"^paid:", text, re.M):
            open(makefile_path, "a").write("paid:\n\t@true\n")

    def remove_paid():
        data = json.load(open(catalog_path))
        data["targets"] = [t for t in data["targets"] if t["name"] != "paid"]
        json.dump(data, open(catalog_path, "w"))
        text = open(makefile_path).read()
        text = re.sub(r"paid:\n(?:\t.*\n)*", "", text)
        open(makefile_path, "w").write(text)

    if action == "add":
        add_paid(sys.argv[2])
    elif action == "remove":
        remove_paid()
    else:
        raise SystemExit("unknown harness-edit-tool action: %s" % action)
    '''
  end

  # A Developer turn applies HARNESS_EDIT_<call>, sees the inactive Stop
  # script answer continue, and ends with a fixed note; a controller
  # verification-failure resume of the same call applies
  # HARNESS_RESUME_EDIT_<call> instead. The Reviewer always accepts.
  defp harness_provider do
    ~S'''
    #!/usr/bin/env python3
    import json, os, pathlib, subprocess, sys
    # Scratch state lives in the Build's harness home (kept after publication
    # removes the Candidate); outside a Build it falls back to the cwd's
    # ignored .kogen/runtime.
    home = os.environ.get("KOGEN_HARNESS_HOME")
    runtime = pathlib.Path(home) / "fake-state" if home else pathlib.Path(".kogen/runtime")
    runtime.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]; prompt = sys.stdin.read()
    def count(name):
        path = runtime / name
        value = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(value)); return value
    if os.environ.get("KOGEN_ROLE") == "reviewer":
        n = count("reviews")
        (runtime / f"reviewer-prompt-{n}").write_text(prompt)
        out = args[args.index("--output-last-message") + 1]
        response = subprocess.run([sys.executable, os.environ["HANDOFF_RESPONSE_HELPER"], "reviewer", "accept"],
                                  input=prompt, capture_output=True, text=True, check=True).stdout
        pathlib.Path(out).write_text(response)
        print(json.dumps({"type": "thread.started", "thread_id": f"review-{n}"}))
        print(json.dumps({"type": "turn.completed", "thread_id": f"review-{n}"}))
        raise SystemExit(0)
    if "--output-last-message" in args or "--output-schema" in args:
        raise SystemExit("Developer turn carried a handoff output schema")
    session = "verification-harness-session"
    if prompt.startswith("Controller verification failed after your turn"):
        call = int((runtime / "developer-calls").read_text())
        n = count("verification-resumes")
        (runtime / f"verification-resume-{n}").write_text(prompt)
        edit = os.environ.get(f"HARNESS_RESUME_EDIT_{call}")
        if edit: subprocess.run(["sh", "-c", edit], check=True)
    else:
        call = count("developer-calls")
        (runtime / f"developer-prompt-{call}").write_text(prompt)
        edit = os.environ.get(f"HARNESS_EDIT_{call}")
        if edit: subprocess.run(["sh", "-c", edit], check=True)
    hook = subprocess.run(["sh", ".codex/hooks/check.sh"], input=json.dumps({"session_id": session, "thread_id": session}).encode(),
                          capture_output=True, check=True)
    if json.loads(hook.stdout) != {"continue": True}: raise SystemExit("Stop hook acted without a v1 context")
    print(json.dumps({"type": "thread.started", "thread_id": session}))
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "All scenarios are done; nothing is unfinished."}}))
    print(json.dumps({"type": "turn.completed", "thread_id": session}))
    '''
  end
end
