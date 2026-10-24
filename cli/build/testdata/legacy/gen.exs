# Generates the version 3 checkpoint fixtures of cli/build/legacy_test.go with the real Elixir
# Kogen: the Build map is made the way Kogen.Build.checked/5 makes it and saved by
# Kogen.Build.save/2, and every checkpoint is read back with Kogen.Run.decode_checkpoint/1.
#
# From the repository root (the Elixir project):
#
#     mise exec -- mix run --no-start cli/build/testdata/legacy/gen.exs cli/build/testdata/legacy
#
# The argument is the output folder. The project lives at a fixed path under /tmp (its root
# is part of the state); the tests move it. Git dates and identity are fixed, so the start
# commit, the trees and the landed commit are the same on every run and the tests can build
# the same repository. The run ids are random: manifest.json names them.

defmodule LegacyFixtures do
  alias Kogen.{Build, Config, Gherkin, Intent, Run, Snapshot}

  @base "/tmp/kogen-legacy-fixture"
  @root @base <> "/repo"
  @slug "fixture"
  @env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_AUTHOR_DATE", "2026-10-22T00:00:00Z"},
    {"GIT_COMMITTER_DATE", "2026-10-22T00:00:00Z"}
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
  @modeled_line "Model: model.qnt invariants=Inv,Other seed=7 samples=20 steps=5"

  def main([out]) do
    out = Path.expand(out)
    Enum.each(@env, fn {k, v} -> System.put_env(k, v) end)
    File.rm_rf!(@base)
    File.mkdir_p!(@root)
    File.mkdir_p!(Path.join(@base, "hooks"))
    project!()
    start = git!(["rev-parse", "HEAD"]) |> String.trim()
    write_intent!()

    excluded = Build.clean_paths!(@root, @slug)

    ctx = %{
      start: start,
      config: Config.load!(@root),
      excluded: excluded,
      start_tree: Snapshot.tree(@root, start, excluded)
    }

    ctx = Map.put(ctx, :approval, approve!(ctx.config))

    File.rm_rf!(out <> "/project")
    for f <- Path.wildcard(out <> "/*.checkpoint.json"), do: File.rm!(f)
    File.mkdir_p!(out)
    manifest = cases(ctx, out)

    copy_project!(Path.join(out, "project"), ctx.approval)

    File.write!(
      Path.join(out, "manifest.json"),
      JSON.encode!(
        Map.merge(manifest, %{
          "root" => @root,
          "slug" => @slug,
          "start" => start,
          "start_tree" => ctx.start_tree,
          "tracked" => git!(["ls-tree", "-r", "-z", "--name-only", start]) |> String.split("\0", trim: true),
          "author_env" => Map.new(@env)
        })
      ) <> "\n"
    )
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

  defp write_intent! do
    write!(Intent.intent_md(@slug), @intent_md)
    write!(Intent.feature(@slug), @feature)
    write!(@steps_file, "// steps\n")
  end

  # The approval the way Kogen.Approve writes it.
  defp approve!(config) do
    baseline = Intent.baseline(@root, @slug, config)

    bytes =
      JSON.encode!(%{
        "slug" => @slug,
        "sha256" => Intent.hash(@root, baseline),
        "approver" => "Kogen Fixture <kogen-fixture@example.invalid>",
        "approved_at" => "2026-10-22T00:00:00Z",
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
    File.write!(Path.join(dest, "APPROVAL"), approval)
  end

  # ---- the Build map ----

  defp new_build(ctx, opts \\ []) do
    config = ctx.config
    baseline = Intent.baseline(@root, @slug, config)
    excluded = ctx.excluded
    intent = Keyword.get(opts, :intent) || Intent.read(@root, @slug)
    model = Intent.model(intent)
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
      usage: %{input: 120, cached: 40, output: 31, reasoning: 7},
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
      attempt_usage: %{input: 120, cached: 40, output: 31, reasoning: 7},
      working_context: %{},
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

  # What the builder has said and done so far: the opening message, a reasoning item, a shell
  # call and its output, the answer text (non-ASCII on purpose).
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

  defp save(b, continuation) do
    Process.put(:prompt_cache_states, cache_states())
    b = Build.save(b, continuation)
    {:ok, _doc, _state} = Run.decode_checkpoint(File.read!(Path.join(b.run.dir, "checkpoint.json")))
    b
  end

  # ---- verification pass (the map Kogen.Build.verify/1 makes) ----

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

  # Cucumber Messages of a run in which every step passed.
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

  defp cases(ctx, out) do
    save_case = fn name, b, continuation, meta ->
      b = save(b, continuation)
      File.cp!(Path.join(b.run.dir, "checkpoint.json"), Path.join(out, "#{name}.checkpoint.json"))
      Map.put(meta, "id", b.run.id)
      |> Map.put("checkpoint", "#{name}.checkpoint.json")
      |> Map.put("pass_tree", b.last_pass && b.last_pass.tree)
      |> then(&{name, &1})
    end

    {first, input} = conversation()

    # builder: interrupted while a request was in flight.
    b = new_build(ctx) |> with_context(first)
    builder = save_case.("builder", b, %{stage: :builder, input: input}, %{"edits" => %{}})

    # builder_verify: the builder finished; the fixers and a pass were next.
    finish = %{
      "type" => "function_call",
      "id" => "fc_2",
      "call_id" => "call_2",
      "name" => "finish",
      "arguments" => ~s({"summary":"nothing to change"}),
      "status" => "completed"
    }

    b = new_build(ctx) |> with_context(first)

    verify =
      save_case.(
        "builder_verify",
        b,
        %{stage: :builder_verify, input: input ++ [finish], finish: finish},
        %{"edits" => %{}}
      )

    # tool, commit, startup: boundaries a resume refuses.
    b = new_build(ctx) |> with_context(first)

    tool =
      save_case.(
        "tool",
        b,
        %{
          stage: :tool,
          owner: :builder,
          input: input,
          completed: %{call: List.last(input), result: "baseline\n"}
        },
        %{"edits" => %{}}
      )

    b = new_build(ctx) |> with_context(first)
    startup = save_case.("startup", %{b | phase: :startup}, %{stage: :startup}, %{"edits" => %{}})

    # blocker: the builder reported a protected-contract blocker.
    b = %{
      new_build(ctx)
      | blocker: %{
          "paths" => ["accept.sh"],
          "reason" => "the fixture contradicts itself",
          "evidence" => "step X fails",
          "classification" => "BUILDER-REPORTED"
        }
    }

    blocker = save_case.("blocker", b, %{stage: :builder, input: input}, %{"edits" => %{}})

    # The candidate the review stages judge.
    File.write!(Path.join(@root, "app.txt"), "candidate\n")
    edits = %{"app.txt" => "candidate\n"}

    review_b = fn extra ->
      b = new_build(ctx) |> with_context(first)
      pass = green_pass(b, 1)
      b = %{b | last_pass: pass, pass: 1, review: 1, repairs: 0} |> Map.merge(extra)
      {b, pass}
    end

    session = fn ->
      reviewer_first = %{
        "role" => "user",
        "content" =>
          Kogen.PromptCache.contract_blocks(
            "# Intent\n\nPreserve the fixture\n# acceptance.feature\n\n" <> @feature,
            "# Check results of the final pass\n\nacceptance: passed (2 scenarios)\n"
          )
      }

      %{
        role: ctx.config.models["review"],
        input: [reviewer_first],
        tools:
          Kogen.Tools.defs(~w(read_file view_image list_files search_text write_file shell)) ++
            [submit_def()],
        usage: %{input: 0, cached: 0, output: 0, reasoning: 0},
        attempts: []
      }
    end

    {b, pass} = review_b.(%{})
    review = save_case.("review", b, %{stage: :review, pass: pass, session: session.()}, %{"edits" => edits})

    {b, pass} = review_b.(%{})
    tree = pass.tree
    ses = session.()
    verdict = %{verdict: "approve", findings: [%{"path" => "app.txt", "line" => 1, "severity" => "note", "message" => "fine — ✓"}]}
    answered = ses.input ++ [%{"role" => "user", "content" => "Final verification passed."}]

    review_verify =
      save_case.(
        "review_verify",
        b,
        %{
          stage: :review_verify,
          pass: pass,
          session: ses,
          verdict: verdict,
          usage: %{input: 9, cached: 3, output: 4, reasoning: 1},
          input: answered,
          tree: tree
        },
        %{"edits" => edits}
      )

    {b, pass} = review_b.(%{})
    blocking = %{"path" => "app.txt", "line" => 1, "severity" => "blocking", "message" => "Original unresolved requirement"}
    changes = %{verdict: "changes", findings: [blocking]}

    b = %{
      b
      | last_review: %{verdict: "pending", findings: [blocking], n: 1, tree: tree}
    }

    retry =
      save_case.(
        "review_retry_verify",
        b,
        %{
          stage: :review_retry_verify,
          pass: pass,
          session: %{ses | attempts: [%{pass: 1, tree: tree, verdict: "changes", findings: [blocking]}]},
          verdict: changes,
          usage: %{input: 9, cached: 3, output: 4, reasoning: 1},
          input: answered,
          tree: tree
        },
        %{"edits" => edits}
      )

    # A Build whose model is a Quint model: only read, never resumed.
    modeled_text = String.replace(@intent_md, ~r/^Model:.*$/m, @modeled_line)
    modeled = Intent.read(@root, @slug, %{Intent.intent_md(@slug) => modeled_text})
    b = new_build(ctx, intent: modeled) |> with_context(first)
    pass = %{green_pass(b, 1) | model: {:ok, []}}
    b = %{b | last_pass: pass, pass: 1, review: 1}

    model =
      save_case.(
        "model",
        b,
        %{stage: :review, pass: pass, session: session.()},
        %{"edits" => edits, "model_line" => @modeled_line}
      )

    # commit: the staged tree is being committed.
    {b, pass} = review_b.(%{})
    approve_review = %{verdict: "approve", findings: [], n: 1, tree: pass.tree}
    b = %{b | last_review: approve_review}
    committing = save_case.("commit", b, %{stage: :commit, tree: pass.tree}, %{"edits" => edits})

    # landed: the commit as Kogen makes it.
    git!(["add", "-A"])
    msg = Path.join(b.run.dir, "commit-message.txt")
    File.write!(msg, "Preserve the fixture\n\nKogen-Intent: #{@slug}\n")
    git!(["commit", "-q", "-F", msg])
    commit = git!(["rev-parse", "HEAD"]) |> String.trim()
    File.rm!(Intent.approval_path(@root, @slug))
    landed = save_case.("landed", b, %{stage: :landed, commit: commit}, %{"edits" => edits, "commit" => commit})

    # Variants of the builder checkpoint that must be refused with their own reasons.
    good = File.read!(Path.join(out, "builder.checkpoint.json")) |> JSON.decode!()
    state_text = good["state"]
    binary = Base.decode64!(state_text)
    put = fn name, doc -> File.write!(Path.join(out, name <> ".checkpoint.json"), JSON.encode!(doc) <> "\n") end
    put.("version2", %{good | "version" => 2})
    put.("damaged-truncated", %{good | "state" => Base.encode64(binary_part(binary, 0, div(byte_size(binary), 2)))})
    put.("damaged-garbage", %{good | "state" => Base.encode64("this is not an Erlang term")})

    # A real map without its phase: valid term, missing required field.
    {:ok, _, saved} = Run.decode_checkpoint(File.read!(Path.join(out, "builder.checkpoint.json")))
    put.("malformed-no-phase", %{good | "state" => Base.encode64(:erlang.term_to_binary(Map.delete(saved, :phase)))})

    put.("malformed-phase", %{good | "state" => Base.encode64(:erlang.term_to_binary(%{saved | phase: :elsewhere}))})

    File.write!(Path.join(@root, "app.txt"), "baseline\n")

    Map.new(
      [builder, verify, tool, startup, blocker, review, review_verify, retry, model, committing, landed],
      fn {name, meta} -> {name, meta} end
    )
    |> then(&%{"cases" => &1})
  end

  # The submit_review tool as Kogen.Review defines it.
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

LegacyFixtures.main(System.argv())
