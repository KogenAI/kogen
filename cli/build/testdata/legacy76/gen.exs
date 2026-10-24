# Generates the version 3 checkpoint fixtures of the CURRENT Elixir Kogen (main 76109e1a) that
# cli/build/legacy76_test.go reads: builder and reviewer stages, a builder-reported blocker
# with its raw candidate identity, nullable usage, and a staged Build with durable stage
# progress and stage evidence in private custody. Like testdata/legacy/gen.exs (bdfd607), the
# Build map is made the way Kogen.Build.checked/5 makes it and saved by Kogen.Build.save/2,
# and every checkpoint is read back with Kogen.Run.decode_checkpoint/1 (except the ones that
# case documents as refused).
#
# From the repository root (the Elixir project, at main 76109e1a):
#
#     mise exec -- mix run --no-start cli/build/testdata/legacy76/gen.exs cli/build/testdata/legacy76
#
# The argument is the output folder. Two projects are written (project/: no stages;
# staged-project/: the same Intent with a two stage plan and a second approval). The projects
# live under /tmp (their root is part of the state); the tests move them. Git dates and
# identity are fixed, so the start commit, the trees and the landed commit are the same on
# every run. The run ids and stage evidence file names are random: manifest.json names them.

defmodule Legacy76Fixtures do
  alias Kogen.{Build, Config, Gherkin, Intent, Run, Snapshot, Stages}

  @base "/private/tmp/kogen-legacy76-fixture"
  @root @base <> "/repo"
  @slug "fixture"
  @env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_AUTHOR_DATE", "2026-10-24T00:00:00Z"},
    {"GIT_COMMITTER_DATE", "2026-10-24T00:00:00Z"}
  ]

  @feature "Feature: Integration fixture\n  Scenario: First\n    Given the fixture is available\n    Then the acceptance check passes\n  Scenario: Second\n    Then the acceptance check passes\n"
  @steps_file "features/steps/integration_steps.js"
  @intent_md """
  # Preserve the fixture

  Slug: fixture
  Model: not applicable — no model for this fixture

  Acceptance:
  - .kogen/intents/fixture/acceptance.feature
  - features/steps/integration_steps.js

  ## Tests
  - the fixture stays as it is: the acceptance scenario (existing)

  ## Source comparison
  - addressed: preserve app.txt fixture behavior; source request; contract Tests and acceptance.feature.

  ## Feasibility
  - none
  """
  @plan %{
    "version" => 1,
    "stages" => [
      %{
        "id" => "foundation",
        "title" => "Foundation",
        "goal" => "First runnable section — é",
        "checks" => ["test -f app.txt", "grep -q . app.txt"]
      },
      %{
        "id" => "surface",
        "title" => "Surface",
        "goal" => "Integrate the second section",
        "checks" => ["true"]
      }
    ]
  }

  def main([out]) do
    out = Path.expand(out)
    Enum.each(@env, fn {k, v} -> System.put_env(k, v) end)
    File.rm_rf!(@base)
    File.mkdir_p!(@root)
    File.mkdir_p!(Path.join(@base, "hooks"))
    project!()
    start = git!(["rev-parse", "HEAD"]) |> String.trim()

    File.rm_rf!(out)
    File.mkdir_p!(out)

    plain = generate!(out, "", "project", start, @intent_md, nil)

    staged_md = @intent_md <> "\n## Stages\n```json\n" <> JSON.encode!(@plan) <> "\n```\n"
    staged = generate!(out, "staged_", "staged-project", start, staged_md, @plan["stages"])

    File.write!(
      Path.join(out, "manifest.json"),
      JSON.encode!(%{
        "root" => @root,
        "slug" => @slug,
        "start" => start,
        "tracked" => git!(["ls-tree", "-r", "-z", "--name-only", start]) |> String.split("\0", trim: true),
        "author_env" => Map.new(@env),
        "cases" => Map.merge(plain, staged)
      }) <> "\n"
    )
  end

  # One project (an Intent text and its approval) and every case that Build can be in.
  defp generate!(out, prefix, project_dir, start, intent_md, plan) do
    reset_checkout!(start)
    write!(Intent.intent_md(@slug), intent_md)
    write!(Intent.feature(@slug), @feature)
    write!(@steps_file, "// steps\n")

    excluded = Build.clean_paths!(@root, @slug)

    ctx = %{
      start: start,
      config: Config.load!(@root),
      excluded: excluded,
      start_tree: Snapshot.tree(@root, start, excluded),
      plan: plan
    }

    ctx = Map.put(ctx, :approval, approve!(ctx.config))
    cases = cases(ctx, out, prefix, intent_md)
    copy_project!(Path.join(out, project_dir), ctx.approval)
    reset_checkout!(start)
    cases
  end

  defp reset_checkout!(start) do
    git!(["reset", "-q", "--hard", start])
    git!(["clean", "-qfdx", "--exclude=.kogen/local/runs"])
    File.rm_rf!(Path.join(@root, ".kogen/intents"))
    File.rm_rf!(Path.join(@root, ".kogen/local/approvals"))
    File.rm_rf!(Path.join(@root, ".kogen/local/runs"))
    File.rm_rf!(Path.join(@root, ".kogen/local/facts"))
    File.rm_rf!(Path.join(@root, "src"))
  end

  # ---- the project ----

  defp project! do
    git!(["init", "-q", "--initial-branch=main"])
    git!(["config", "user.name", "Kogen Fixture"])
    git!(["config", "user.email", "kogen-fixture@example.invalid"])
    git!(["config", "commit.gpgsign", "false"])
    git!(["config", "core.hooksPath", Path.join(@base, "hooks")])

    write!("README.md", "# Fixture project\n")
    write!("app.txt", "baseline\n")
    write!(".gitignore", ".kogen/local/\n")
    write!("accept.sh", "#!/bin/sh\ncp reports/green.ndjson \"$KOGEN_ACCEPTANCE_REPORT\"\n")
    File.chmod!(Path.join(@root, "accept.sh"), 0o755)

    {:ok, scenarios} = Gherkin.parse(@feature)
    write!("reports/green.ndjson", report(scenarios))

    write!(
      Config.path(),
      Config.render(%{
        setup: ["true"],
        fix: ["true"],
        checks: [%{name: "lint", run: "test -f app.txt"}, %{name: "unit", run: "grep -q . app.txt"}],
        protect: ["accept.sh"],
        acceptance: %{run: "sh accept.sh", steps_dir: "features/steps"}
      })
    )

    git!(["add", "README.md", "app.txt", ".gitignore", "accept.sh", "reports", Config.path()])
    git!(["commit", "-q", "-m", "fixture baseline"])
  end

  # The approval the way Kogen.Approve writes it.
  defp approve!(config) do
    baseline = Intent.baseline(@root, @slug, config)

    bytes =
      JSON.encode!(%{
        "slug" => @slug,
        "sha256" => Intent.hash(@root, baseline),
        "approver" => "Kogen Fixture <kogen-fixture@example.invalid>",
        "approved_at" => "2026-10-24T00:00:00Z",
        "source_provenance" => nil
      }) <> "\n"

    path = Intent.approval_path(@root, @slug)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    bytes
  end

  defp copy_project!(dest, approval) do
    files =
      git!(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
      |> String.split("\0", trim: true)

    for f <- files do
      File.mkdir_p!(Path.dirname(Path.join(dest, f)))
      File.cp!(Path.join(@root, f), Path.join(dest, f))
    end

    # app.txt as the start commit has it (a case may have left an edit).
    File.write!(Path.join(dest, "app.txt"), "baseline\n")
    File.rm_rf!(Path.join(dest, "src"))
    File.write!(Path.join(dest, "APPROVAL"), approval)
  end

  # ---- the Build map (what Kogen.Build.checked/5 makes at main 76109e1a) ----

  defp new_build(ctx, opts \\ []) do
    config = ctx.config
    baseline = Intent.baseline(@root, @slug, config)
    excluded = ctx.excluded
    intent = Keyword.get(opts, :intent) || Intent.read(@root, @slug)
    model = Intent.model(intent)
    {:ok, stage_plan} = Stages.parse(intent.text)
    run = Run.start(@root)
    Process.delete(:kogen_build)
    Process.delete(:local_failure)
    Kogen.LocalFacts.start(@root, @slug, run)

    git_index =
      Path.join(git!(["rev-parse", "--absolute-git-dir"]) |> String.trim(), "index")

    File.cp!(git_index, Path.join(run.dir, "index-at-start"))

    %{
      root: @root,
      slug: @slug,
      config: config,
      intent: intent,
      model: model,
      start: ctx.start,
      baseline: baseline,
      excluded: excluded,
      run: run,
      baseline_digests: Map.new(baseline, &{&1, digest(&1)}),
      git_index: git_index,
      start_tree: ctx.start_tree,
      phase: :building,
      t0: System.monotonic_time(:millisecond),
      usage: Keyword.get(opts, :usage, %{input: 120, cached: 40, output: 31, reasoning: 7}),
      round: 1,
      pass: 0,
      review: 0,
      repairs: 0,
      last_pass: nil,
      last_review: nil,
      blocker: nil,
      continuation: %{stage: :startup},
      approval_bytes: Base.encode64(ctx.approval),
      parent: nil,
      root_run: nil,
      model_active_ms: 1234,
      unknown_requests: 0,
      attempt_usage: Keyword.get(opts, :usage, %{input: 120, cached: 40, output: 31, reasoning: 7}),
      working_context: %{},
      stage_plan: stage_plan,
      stage_progress: Stages.initial(stage_plan),
      stage_evidence: [],
      source_provenance: nil
    }
  end

  defp digest(path) do
    case File.read(Path.join(@root, path)) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      _ -> :missing
    end
  end

  defp cache_states do
    key = Base.encode16(:crypto.hash(:sha256, "fixture conversation"), case: :lower)
    %{key => %{id: "conversation-fixture-1", unsupported: false, response: "resp_fixture_1"}}
  end

  defp conversation do
    first = %{
      "role" => "user",
      "content" =>
        Kogen.PromptCache.contract_blocks(
          "# Intent: Preserve the fixture\n\nThe stable authority — naïve ✓\n",
          "# Files\n\nREADME.md\napp.txt\n"
        )
    }

    call = %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "call_1",
      "name" => "shell",
      "arguments" => ~s({"command":"cat app.txt"}),
      "status" => "completed"
    }

    reasoning = %{
      "type" => "reasoning",
      "id" => "rs_1",
      "summary" => [%{"type" => "summary_text", "text" => "Look at app.txt first."}],
      "encrypted_content" => "gAAAAABfixture==",
      "status" => "completed"
    }

    {first, [first, reasoning, call, Kogen.Shape.output(call, "baseline\n")]}
  end

  defp with_context(b, first) do
    %{
      b
      | working_context: %{
          "build" => %{history: [], mandatory: [first], observations: ["finished a read ✓"]}
        }
    }
  end

  defp save(b, continuation, check) do
    Process.put(:prompt_cache_states, cache_states())
    b = Build.save(b, continuation)

    if check do
      {:ok, _doc, _state} = Run.decode_checkpoint(File.read!(Path.join(b.run.dir, "checkpoint.json")))
    end

    b
  end

  # ---- verification passes (the maps Kogen.Build.verify/2 makes) ----

  defp green_pass(b, n) do
    {:ok, expected} = Gherkin.parse(@feature)
    report = Path.join(b.run.dir, "acceptance-#{n}.ndjson")
    File.write!(report, report(expected))

    acceptance =
      Kogen.Checks.account(@root, Intent.feature(@slug), expected, report, %{status: 0, output: ""})

    check = fn name, cmd -> %{name: name, command: cmd, status: 0, output: ""} end

    %{
      n: n,
      tree: Snapshot.tree(@root, b.start, b.excluded),
      clean: true,
      acceptance: acceptance,
      model: if(b.model == :none, do: :none, else: {:ok, []}),
      checks: [check.("lint", "test -f app.txt"), check.("unit", "grep -q . app.txt")],
      setup: [check.("setup-1", "true")],
      not_run: [],
      moved: [],
      failing: [],
      green: true
    }
  end

  # A stage gate's pass: setup, then only the stage's checks; no acceptance, no model.
  defp stage_pass(b, n, stage, red \\ false) do
    check = fn name, cmd, status, output ->
      %{name: name, command: cmd, status: status, output: output}
    end

    checks =
      Enum.with_index(stage["checks"], 1)
      |> Enum.map(fn {cmd, i} ->
        if red and i == 1,
          do: check.("stage-#{stage["id"]}-#{i}", cmd, 23, "scoped red — ✗\n"),
          else: check.("stage-#{stage["id"]}-#{i}", cmd, 0, "")
      end)

    ran = if red, do: Enum.take(checks, 1), else: checks
    not_run = if red, do: tl(Enum.map(checks, & &1.name)), else: []

    %{
      n: n,
      tree: Snapshot.tree(@root, b.start, b.excluded),
      clean: true,
      acceptance: :not_run,
      model: if(b.model == :none, do: :none, else: :not_run),
      checks: ran,
      setup: [check.("setup-1", "true", 0, "")],
      not_run: not_run,
      moved: [],
      failing: if(red, do: ["stage-#{stage["id"]}-1"], else: []),
      green: not red
    }
  end

  # Stage evidence the way Kogen.Build.verify_stage/1 records it (a private file per record).
  defp evidence(b, pass, stage, index) do
    e = Map.merge(pass, %{stage_id: stage["id"], stage_index: index, contract: b.approval_bytes})
    Stages.retain(b, e)
  end

  defp report(scenarios) do
    feature = Intent.feature(@slug)

    doc = %{
      "gherkinDocument" => %{
        "uri" => feature,
        "feature" => %{
          "children" =>
            for {s, i} <- Enum.with_index(scenarios, 1) do
              %{
                "scenario" => %{
                  "id" => "ast-scenario-#{i}",
                  "location" => %{"line" => s.line},
                  "steps" =>
                    for {st, j} <- Enum.with_index(s.steps, 1) do
                      %{
                        "id" => "ast-step-#{i}-#{j}",
                        "location" => %{"line" => st.line},
                        "keyword" => st.keyword
                      }
                    end,
                  "examples" => []
                }
              }
            end
        }
      }
    }

    cases =
      for {s, i} <- Enum.with_index(scenarios, 1) do
        p = "case-#{i}"
        steps = Enum.with_index(s.steps, 1)

        [
          %{
            "pickle" => %{
              "id" => p <> "-pickle",
              "uri" => feature,
              "name" => s.name,
              "astNodeIds" => ["ast-scenario-#{i}"],
              "steps" =>
                for {st, j} <- steps do
                  %{
                    "id" => "#{p}-pickle-step-#{j}",
                    "astNodeIds" => ["ast-step-#{i}-#{j}"],
                    "text" => st.text
                  }
                end
            }
          },
          %{
            "testCase" => %{
              "id" => p <> "-case",
              "pickleId" => p <> "-pickle",
              "testSteps" =>
                for {_, j} <- steps do
                  %{"id" => "#{p}-test-step-#{j}", "pickleStepId" => "#{p}-pickle-step-#{j}"}
                end
            }
          },
          %{"testCaseStarted" => %{"id" => p <> "-started", "testCaseId" => p <> "-case"}}
        ] ++
          for {_, j} <- steps do
            %{
              "testStepFinished" => %{
                "testCaseStartedId" => p <> "-started",
                "testStepId" => "#{p}-test-step-#{j}",
                "testStepResult" => %{"status" => "PASSED"}
              }
            }
          end ++
          [%{"testCaseFinished" => %{"testCaseStartedId" => p <> "-started", "willBeRetried" => false}}]
      end

    Enum.map_join([doc | List.flatten(cases)], "\n", &JSON.encode!/1) <> "\n"
  end

  # ---- the cases ----

  defp cases(ctx, out, prefix, intent_md) do
    # Saves a case and returns {name, metadata}. `custody` lists the private files of the
    # run folder (stage evidence) the case needs next to the checkpoint.
    save_case = fn name, b, continuation, meta, opts ->
      b = save(b, continuation, Keyword.get(opts, :check, true))
      name = prefix <> name
      File.cp!(Path.join(b.run.dir, "checkpoint.json"), Path.join(out, "#{name}.checkpoint.json"))

      custody =
        for e <- b.stage_evidence, into: %{} do
          file = Path.basename(e.custody["path"])
          dest = Path.join([out, "custody", name])
          File.mkdir_p!(dest)
          File.cp!(e.custody["path"], Path.join(dest, file))
          {file, "custody/#{name}/#{file}"}
        end

      meta
      |> Map.put("id", b.run.id)
      |> Map.put("checkpoint", "#{name}.checkpoint.json")
      |> Map.put("pass_tree", b.last_pass && b.last_pass.tree)
      |> Map.put("project", if(ctx.plan, do: "staged-project", else: "project"))
      |> Map.put("start_tree", ctx.start_tree)
      |> Map.put("custody", custody)
      |> then(&{name, &1})
    end

    {first, input} = conversation()
    plain = fn -> new_build(ctx) |> with_context(first) end

    if ctx.plan do
      finish = %{
        "type" => "function_call",
        "id" => "fc_2",
        "call_id" => "call_2",
        "name" => "finish",
        "arguments" => ~s({"summary":"nothing to change"}),
        "status" => "completed"
      }

      _ = intent_md
      Map.new(staged_cases(ctx, save_case, first, input, finish))
    else
      plain_cases(ctx, save_case, first, input, plain)
    end
  end

  defp plain_cases(ctx, save_case, first, input, plain) do

    # builder: interrupted while a request was in flight.
    builder = save_case.("builder", plain.(), %{stage: :builder, input: input}, %{"edits" => %{}}, [])

    finish = %{
      "type" => "function_call",
      "id" => "fc_2",
      "call_id" => "call_2",
      "name" => "finish",
      "arguments" => ~s({"summary":"nothing to change"}),
      "status" => "completed"
    }

    verify =
      save_case.(
        "builder_verify",
        plain.(),
        %{stage: :builder_verify, input: input ++ [finish], finish: finish},
        %{"edits" => %{}},
        []
      )

    # tool: the builder's own loop saved it (owner :builder) ...
    tool =
      save_case.(
        "tool",
        plain.(),
        %{
          stage: :tool,
          owner: :builder,
          input: input,
          completed: %{call: List.last(input), result: "baseline\n"}
        },
        %{"edits" => %{}},
        []
      )

    # ... and a model request saved this one (its role as text, with the response items).
    tool_request =
      save_case.(
        "tool_request",
        plain.(),
        %{stage: :tool, owner: "build", response: [List.last(input)]},
        %{"edits" => %{}},
        []
      )

    startup =
      save_case.(
        "startup",
        %{plain.() | phase: :startup},
        %{stage: :startup},
        %{"edits" => %{}},
        []
      )

    # nullable usage: a request that did not report every count (an Anthropic response).
    nullable =
      save_case.(
        "nullable_usage",
        %{new_build(ctx, usage: %{input: nil, output: 1, cached: nil, reasoning: nil}) | working_context: %{}},
        %{stage: :builder, input: input},
        %{"edits" => %{}},
        []
      )

    # blocker: the builder reported a protected-contract blocker (no edits, and with edits).
    blocker_map = %{
      "paths" => ["accept.sh"],
      "reason" => "the fixture contradicts itself",
      "evidence" => "step X fails",
      "classification" => "BUILDER-REPORTED"
    }

    blocker =
      save_case.(
        "blocker",
        %{new_build(ctx) | blocker: blocker_map},
        %{stage: :builder, input: input},
        %{"edits" => %{}},
        []
      )

    File.mkdir_p!(Path.join(@root, "src"))
    File.write!(Path.join(@root, "src/new.txt"), "implementation Δ🙂\n")
    File.write!(Path.join(@root, "app.txt"), "candidate\n")
    File.chmod!(Path.join(@root, "src/new.txt"), 0o755)

    blocker_edits =
      save_case.(
        "blocker_edits",
        %{new_build(ctx) | blocker: blocker_map},
        %{stage: :tool, owner: :builder, input: input},
        %{"edits" => %{"app.txt" => "candidate\n", "src/new.txt" => "implementation Δ🙂\n"}, "modes" => %{"src/new.txt" => "755"}},
        []
      )

    File.rm_rf!(Path.join(@root, "src"))

    # The candidate the review stages judge.
    File.write!(Path.join(@root, "app.txt"), "candidate\n")
    edits = %{"app.txt" => "candidate\n"}

    review_b = fn extra ->
      b = new_build(ctx) |> with_context(first)
      pass = green_pass(b, 1)
      b = %{b | last_pass: pass, pass: 1, review: 1, repairs: 0} |> Map.merge(extra)
      {b, pass}
    end

    # The reviewer's conversation: its opening message still carries the candidate source
    # inline, remembered with the tree and material it was made from.
    session = fn b, pass ->
      material = %{
        authority: "# Intent\n\nPreserve the fixture\n# acceptance.feature\n\n" <> @feature,
        source:
          "# Check results of the final pass\n\nacceptance: passed (2 scenarios)\n\n# Diff of existing/deleted paths against start HEAD\n\ndiff --git a/app.txt b/app.txt\n",
        files: [
          %{
            "path" => "app.txt",
            "status" => "changed",
            "mode" => "100644",
            "git_object" => String.duplicate("a", 40),
            "bytes" => 10,
            "sha256" => String.duplicate("b", 64)
          }
        ],
        checks: "acceptance: passed (2 scenarios)"
      }

      tools =
        Kogen.Tools.defs(~w(read_file view_image list_files search_text write_file shell)) ++
          [submit_def()]

      role = ctx.config.models["review"]

      {b, reviewer_input} =
        Kogen.ReviewMaterial.prepare(b, pass.tree, material, role, "reviewer policy", tools, [])

      {b,
       %{
         role: role,
         input: reviewer_input,
         tools: tools,
         usage: %{input: 0, cached: 0, output: 0, reasoning: 0},
         attempts: []
       }}
    end

    {b, pass} = review_b.(%{})
    {b, ses} = session.(b, pass)
    review = save_case.("review", Stages.phase(b, "review"), %{stage: :review, pass: pass, session: ses}, %{"edits" => edits}, [])

    {b, pass} = review_b.(%{})
    {b, ses} = session.(b, pass)
    tree = pass.tree

    verdict = %{
      verdict: "approve",
      findings: [%{"path" => "app.txt", "line" => 1, "severity" => "note", "message" => "fine — ✓"}]
    }

    answered = ses.input ++ [%{"role" => "user", "content" => "Final verification passed."}]

    review_verify =
      save_case.(
        "review_verify",
        Stages.phase(b, "review"),
        %{
          stage: :review_verify,
          pass: pass,
          session: ses,
          verdict: verdict,
          usage: %{input: 9, cached: 3, output: 4, reasoning: 1},
          input: answered,
          tree: tree
        },
        %{"edits" => edits},
        []
      )

    {b, pass} = review_b.(%{})
    {b, ses} = session.(b, pass)

    blocking = %{
      "path" => "app.txt",
      "line" => 1,
      "severity" => "blocking",
      "message" => "Original unresolved requirement"
    }

    changes = %{verdict: "changes", findings: [blocking]}
    b = %{b | last_review: %{verdict: "pending", findings: [blocking], n: 1, tree: tree}}

    retry =
      save_case.(
        "review_retry_verify",
        Stages.phase(b, "review"),
        %{
          stage: :review_retry_verify,
          pass: pass,
          session: %{ses | attempts: [%{pass: 1, tree: tree, verdict: "changes", findings: [blocking]}]},
          verdict: changes,
          usage: %{input: 9, cached: 3, output: 4, reasoning: 1},
          input: answered,
          tree: tree
        },
        %{"edits" => edits},
        []
      )

    # commit: the staged tree is being committed.
    {b, pass} = review_b.(%{})
    approve_review = %{verdict: "approve", findings: [], n: 1, tree: pass.tree}
    b = %{b | last_review: approve_review}
    committing = save_case.("commit", Stages.phase(b, "review"), %{stage: :commit, tree: pass.tree}, %{"edits" => edits}, [])

    # landed: the commit as Kogen makes it.
    git!(["add", "-A"])
    msg = Path.join(b.run.dir, "commit-message.txt")
    File.write!(msg, "Preserve the fixture\n\nKogen-Intent: #{@slug}\n")
    git!(["commit", "-q", "-F", msg])
    commit = git!(["rev-parse", "HEAD"]) |> String.trim()
    File.rm!(Intent.approval_path(@root, @slug))

    landed =
      save_case.(
        "landed",
        Stages.phase(b, "landed"),
        %{stage: :landed, commit: commit},
        %{"edits" => edits, "commit" => commit},
        []
      )

    Map.new([builder, verify, tool, tool_request, startup, nullable, blocker, blocker_edits, review, review_verify, retry, committing, landed])
  end

  # Cases of a staged Build: the plan's progress and the evidence of each stage gate.
  defp staged_cases(ctx, save_case, first, input, finish) do
    File.write!(Path.join(@root, "app.txt"), "baseline\n")
    [one, two] = ctx.plan

    build = fn ->
      b = new_build(ctx) |> with_context(first)
      %{b | pass: 0}
    end

    # A red gate for the first stage, then the green one: the Build is at the second stage.
    b0 = build.()
    red_pass = stage_pass(b0, 1, one, true)
    red = evidence(b0, red_pass, one, 1)
    b1 = %{b0 | pass: 1, stage_evidence: [red]}
    first_red = save_case.("builder_red", b1, %{stage: :builder, input: input}, %{"edits" => %{}}, [])

    File.write!(Path.join(@root, "app.txt"), "phase-one\n")
    green_pass = stage_pass(b1, 2, one)
    green = evidence(b1, green_pass, one, 1)

    b2 = %{
      b1
      | pass: 2,
        stage_evidence: [red, green],
        stage_progress: %{
          "total" => 2,
          "completed" => ["foundation"],
          "active" => "surface",
          "phase" => "stage"
        }
    }

    edits = %{"app.txt" => "phase-one\n"}
    next = input ++ [Kogen.Shape.output(finish, "Stage foundation passed. Continue the next stage. " <> Stages.navigation(b2))]
    second = save_case.("builder_second", b2, %{stage: :builder, input: next}, %{"edits" => edits}, [])

    second_verify =
      save_case.(
        "builder_second_verify",
        b2,
        %{stage: :builder_verify, input: input ++ [finish], finish: finish},
        %{"edits" => edits},
        []
      )

    second_tool =
      save_case.(
        "tool_second",
        b2,
        %{stage: :tool, owner: :builder, input: input, completed: %{call: List.last(input), result: "baseline\n"}},
        %{"edits" => edits},
        []
      )

    # The last stage passed too: the whole Intent's gates, review and commit are next.
    File.write!(Path.join(@root, "app.txt"), "phase-two\n")
    surface_pass = stage_pass(b2, 3, two)
    surface = evidence(b2, surface_pass, two, 2)

    b3 = %{
      b2
      | pass: 3,
        stage_evidence: [red, green, surface],
        stage_progress: %{
          "total" => 2,
          "completed" => ["foundation", "surface"],
          "active" => nil,
          "phase" => "final"
        }
    }

    edits3 = %{"app.txt" => "phase-two\n"}

    final =
      save_case.(
        "builder_final",
        b3,
        %{stage: :builder_verify, input: input ++ [finish], finish: finish},
        %{"edits" => edits3},
        []
      )

    # review: the reviewer judges the final tree; stage evidence stays historical.
    pass = %{green_pass(b3, 4) | n: 4}
    b4 = %{b3 | pass: 4, last_pass: pass, review: 1}
    b4 = Stages.phase(b4, "review")

    tools =
      Kogen.Tools.defs(~w(read_file view_image list_files search_text write_file shell)) ++
        [submit_def()]

    session = %{
      role: ctx.config.models["review"],
      input: [
        %{
          "role" => "user",
          "content" =>
            Kogen.PromptCache.contract_blocks(
              "# Intent\n\nPreserve the fixture\n",
              "# Check results of the final pass\n\nacceptance: passed (2 scenarios)\n"
            )
        }
      ],
      tools: tools,
      usage: %{input: 0, cached: 0, output: 0, reasoning: 0},
      attempts: []
    }

    review = save_case.("review_final", b4, %{stage: :review, pass: pass, session: session}, %{"edits" => edits3}, [])

    # A request saved a tool boundary: Kogen.Stages gives such a staged state no valid phase.
    tool_request =
      save_case.(
        "tool_request",
        b2,
        %{stage: :tool, owner: "build", response: [List.last(input)]},
        %{"edits" => edits},
        check: false
      )

    # landed: the commit as Kogen makes it.
    b5 = %{b4 | last_review: %{verdict: "approve", findings: [], n: 1, tree: pass.tree}}
    git!(["add", "-A"])
    msg = Path.join(b5.run.dir, "commit-message.txt")
    File.write!(msg, "Preserve the fixture\n\nKogen-Intent: #{@slug}\n")
    git!(["commit", "-q", "-F", msg])
    commit = git!(["rev-parse", "HEAD"]) |> String.trim()
    File.rm!(Intent.approval_path(@root, @slug))

    landed =
      save_case.(
        "landed_final",
        Stages.phase(b5, "landed"),
        %{stage: :landed, commit: commit},
        %{"edits" => edits3, "commit" => commit},
        []
      )

    [first_red, second, second_verify, second_tool, tool_request, final, review, landed]
  end

  defp submit_def do
    %{
      "type" => "function",
      "name" => "submit_review",
      "strict" => false,
      "description" => "Submit the review: verdict approve or changes, with findings.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "verdict" => %{"type" => "string", "enum" => ["approve", "changes"]},
          "findings" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "path" => %{"type" => "string"},
                "line" => %{"type" => "integer"},
                "severity" => %{"type" => "string", "enum" => ["blocking", "note"]},
                "message" => %{"type" => "string"}
              },
              "required" => ["path", "line", "severity", "message"]
            }
          }
        },
        "required" => ["verdict", "findings"]
      }
    }
  end

  # ---- helpers ----

  defp write!(rel, text) do
    path = Path.join(@root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp git!(args) do
    case System.cmd("git", args, cd: @root, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, n} -> raise "git #{Enum.join(args, " ")} failed (#{n}): #{out}"
    end
  end
end

Legacy76Fixtures.main(System.argv())
