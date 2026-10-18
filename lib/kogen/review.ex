defmodule Kogen.Review do
  @moduledoc """
  The blocking review (chapter 06): after a green pass, a fresh request to `models.review` with
  the Intent, the diff of existing/deleted paths against the start HEAD, the full text of every changed/added file and the
  check results, with file/command tools for scoped repairs and `submit_review`. It never sees
  the builder's conversation. Changed contents are verified externally; failures return to this
  same reviewer conversation. An unresolved blocker ends the Build instead of restarting the builder.
  """
  alias Kogen.{Bridge, Build, Error, Git, Intent, Run, Shape, Snapshot, Tools, Usage}

  def run(b, pass, verify) do
    n = b.review + 1
    b = Build.track(%{b | review: n})
    Bridge.progress("kogen: reviewing (review #{n})")
    role = b.config.models["review"]
    input = [%{"role" => "user", "content" => material(b, pass)}]
    tools = Tools.defs(~w(read_file list_files search_text write_file shell)) ++ [submit_def()]
    session = %{role: role, input: input, tools: tools, usage: Usage.zero(), attempts: []}
    finish(b, pass, session, verify)
  end

  defp finish(b, pass, session, verify) do
    n = b.review

    {b, verdict, usage, input} =
      converse(b, session.role, session.input, session.tools, 0, session.usage)

    Build.baseline_intact!(b)
    tree = Snapshot.tree(b.root, b.start, b.excluded)
    review = Map.merge(verdict, %{n: n, tree: tree})
    b = Build.track(%{b | last_review: review})

    attempts =
      session.attempts ++
        [%{pass: pass.n, tree: tree, verdict: verdict.verdict, findings: verdict.findings}]

    blocking = Enum.count(verdict.findings, &(&1["severity"] == "blocking"))
    Bridge.progress("kogen: review #{n}: #{verdict.verdict}, #{blocking} blocking")

    Run.write(b.run, "review-#{n}.json", %{
      "model" => session.role.model,
      "effort" => session.role.effort,
      "usage" => usage,
      "verdict" => verdict.verdict,
      "findings" => verdict.findings,
      "tree" => tree,
      "attempts" => attempts
    })

    Run.log(b.run, %{
      "event" => "review",
      "review" => n,
      "attempt" => length(attempts),
      "pass" => pass.n,
      "tree" => tree,
      "verdict" => verdict.verdict,
      "findings" => verdict.findings
    })

    if verdict.verdict == "changes" do
      lines =
        for f <- verdict.findings,
            f["severity"] == "blocking",
            do: "review: #{f["path"]}:#{f["line"]}: #{f["message"]}"

      throw(
        {:failed, b,
         %Error{
           class: "candidate",
           reason: "review_blocked",
           detail:
             "the reviewer could not resolve a substantive blocker within the approved Intent; edits are left in place",
           lines: lines,
           exit: 1
         }}
      )
    end

    {b, final_pass} =
      if pass.green and tree == pass.tree do
        {b, pass}
      else
        b = Build.track(%{b | last_review: %{review | verdict: "pending"}})
        verify.(b)
      end

    if final_pass.green and final_pass.tree == tree do
      {:approve, Build.track(%{b | last_review: review}), final_pass, review}
    else
      feedback =
        if final_pass.green do
          paths = Snapshot.changed(b.root, tree, final_pass.tree)

          Bridge.progress(
            "kogen: review #{n}: candidate changed after approval; inspecting changed paths"
          )

          "Candidate contents changed after your approval: #{Enum.join(paths, ", ")}. The new tree passed checks but has not been reviewed. Inspect these changes and submit_review for the current contents; do not restart the whole critique."
        else
          Bridge.progress(
            "kogen: review #{n}: final verification failed; continuing targeted repairs"
          )

          "Final verification of your repairs failed. Fix these failures and regressions from your edits; do not restart a whole-change critique. If observed evidence demonstrates a protected fixture defect, use submit_review changes with a blocking finding at that protected path instead of a production workaround, including a test-facing hidden comment.\n" <>
            Build.pass_feedback(b, final_pass, "submit_review")
        end

      b = Build.track(%{b | repairs: b.repairs + 1})

      finish(
        b,
        final_pass,
        %{
          session
          | input: input ++ [%{"role" => "user", "content" => feedback}],
            usage: usage,
            attempts: attempts
        },
        verify
      )
    end
  end

  defp converse(b, role, input, tools, invalid, usage) do
    resp = Build.request(b, "review", role, instructions(), input, tools)
    usage = Usage.add(usage, resp.usage)
    b = Build.track(%{b | usage: Usage.add(b.usage, resp.usage)})
    calls = for %{"type" => "function_call"} = c <- resp.items, do: c
    input = input ++ (Enum.map(resp.items, &Shape.replay_item/1) |> Enum.reject(&is_nil/1))

    ctx = %{
      root: b.root,
      protected: b.baseline,
      tools: ~w(read_file list_files search_text write_file shell)
    }

    {outputs, verdict} =
      Enum.reduce(calls, {[], nil}, fn call, {outs, verdict} ->
        Bridge.check_cancel()

        cond do
          verdict != nil ->
            {outs ++ [Shape.output(call, "ignored: the review already has a verdict")], verdict}

          call["name"] == "submit_review" ->
            case validate(Shape.decode(call), b) do
              {:ok, v} ->
                {outs ++ [Shape.output(call, "accepted")], v}

              {:error, problems} ->
                {outs ++ [Shape.output(call, "invalid verdict:\n" <> Enum.join(problems, "\n"))],
                 {:invalid, problems}}
            end

          true ->
            result = call["name"] |> Tools.run(Shape.decode(call), ctx) |> Tools.cut()

            Run.log(b.run, %{
              "event" => "review_tool_call",
              "name" => call["name"],
              "arguments" => Run.cap(call["arguments"] || ""),
              "result" => Run.cap(result)
            })

            if call["name"] == "shell", do: Build.baseline_intact!(b)

            {outs ++ [Shape.output(call, result)], verdict}
        end
      end)

    input = input ++ outputs

    verdict =
      if calls == [],
        do: {:invalid, ["the review ended without calling submit_review"]},
        else: verdict

    case verdict do
      {:invalid, problems} when invalid >= 1 ->
        Run.log(b.run, %{
          "event" => "review",
          "review" => b.review,
          "verdict" => "invalid",
          "problems" => problems
        })

        b = %{b | last_review: %{verdict: "invalid", findings: [], n: b.review}}

        throw(
          {:failed, b,
           %Error{
             class: "candidate",
             reason: "review_invalid",
             detail: "the reviewer did not return a valid verdict; edits are left in place",
             exit: 1
           }}
        )

      {:invalid, problems} ->
        input =
          if calls == [],
            do:
              input ++
                [
                  %{
                    "role" => "user",
                    "content" =>
                      "Not a valid verdict: " <>
                        Enum.join(problems, "; ") <> ". Call submit_review."
                  }
                ],
            else: input

        converse(b, role, input, tools, invalid + 1, usage)

      nil ->
        converse(b, role, input, tools, invalid, usage)

      v ->
        {b, v, usage, input}
    end
  end

  # REV-4: `changes` has a blocking finding, `approve` none, every path is a repository file.
  defp validate(%{"verdict" => verdict, "findings" => findings}, b)
       when verdict in ["approve", "changes"] and is_list(findings) do
    problems =
      Enum.flat_map(findings, fn
        %{"path" => p, "line" => l, "severity" => s, "message" => m}
        when is_binary(p) and is_integer(l) and s in ["blocking", "note"] and is_binary(m) ->
          if File.regular?(Path.join(b.root, p)) or Git.show(b.root, b.start, p) != nil,
            do: [],
            else: ["#{p} is not a file of the repository"]

        _ ->
          [
            "each finding needs path (string), line (integer), severity (blocking or note) and message"
          ]
      end)

    blocking = Enum.count(findings, &(is_map(&1) and &1["severity"] == "blocking"))

    problems =
      problems ++
        cond do
          verdict == "changes" and blocking == 0 ->
            ["a changes verdict needs at least one blocking finding"]

          verdict == "approve" and blocking > 0 ->
            ["an approve verdict cannot have blocking findings"]

          true ->
            []
        end

    if problems == [],
      do: {:ok, %{verdict: verdict, findings: findings}},
      else: {:error, problems}
  end

  defp validate(_, _b),
    do: {:error, ["submit_review needs verdict (approve or changes) and a findings list"]}

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

  # REV-2: what the reviewer reads.
  defp material(b, pass) do
    files = Snapshot.changed(b.root, b.start, pass.tree)

    original_paths =
      b.root
      |> Git.ok!(["ls-tree", "-r", "--name-only", "-z", b.start])
      |> String.split("\0", trim: true)
      |> MapSet.new()

    existing = Enum.filter(files, &MapSet.member?(original_paths, &1))

    entries =
      b.root
      |> Git.ok!(["ls-tree", "-r", "-z", pass.tree])
      |> String.split("\0", trim: true)
      |> Map.new(fn entry ->
        [metadata, path] = String.split(entry, "\t", parts: 2)
        [mode, _type, object] = String.split(metadata, " ")
        {path, %{mode: mode, object: object}}
      end)

    texts =
      Enum.map_join(files, "\n", fn p ->
        case Map.fetch(entries, p) do
          {:ok, %{mode: mode, object: object}} ->
            heading =
              "--- #{p}" <>
                if(MapSet.member?(original_paths, p),
                  do: "",
                  else: " (added; mode #{mode})"
                )

            if mode == "160000" do
              heading <> "\nSubproject commit #{object}"
            else
              text = Git.ok!(b.root, ["show", "#{pass.tree}:#{p}"])

              if String.valid?(text) and not String.contains?(text, <<0>>),
                do: heading <> "\n#{text}",
                else: heading <> " (binary)"
            end

          _ ->
            "--- #{p} (deleted)"
        end
      end)

    model_text =
      case File.read(Path.join(b.root, Intent.model_path(b.slug))) do
        {:ok, t} -> "\n# model.qnt\n\n#{t}\n"
        _ -> ""
      end

    """
    # Intent

    #{b.intent.text}
    # acceptance.feature

    #{File.read!(Path.join(b.root, Intent.feature(b.slug)))}
    #{model_text}
    # Project instructions (README.md)

    #{Shape.readme(b.root)}

    # Testing rules (docs/testing-rules.md)

    #{Kogen.testing_rules()}

    # Check results of the final pass

    #{results(pass)}

    # Protected paths and configured commands

    The approved baseline cannot change: #{Enum.join(b.baseline, ", ")}.
    Fixers: #{Enum.join(b.config.fix, "; ")}.
    Project checks: #{Enum.map_join(b.config.checks, "; ", fn {name, command} -> "#{name}: #{command}" end)}.
    Acceptance: #{b.config.acceptance_run}.

    # Diff of existing/deleted paths against start HEAD #{String.slice(b.start, 0, 8)}

    #{Snapshot.diff(b.root, b.start, pass.tree, existing)}
    # Full text of every changed or added file

    Newly added files appear here once, with their mode, instead of being repeated in the diff.

    #{texts}
    """
  end

  defp results(pass) do
    model =
      case pass.model do
        :none -> "model: not applicable"
        _ -> "model: passed"
      end

    Enum.join(
      ["acceptance: passed (#{length(pass.acceptance.scenarios)} scenarios)", model] ++
        Enum.map(pass.checks, &"check #{&1.name}: passed"),
      "\n"
    )
  end

  defp instructions do
    """
    You review code that another model wrote to implement an approved Intent in this repository. Every check already passed. Perform one cohesive review and directly repair supported defects within that Intent using read_file, list_files, search_text, write_file and shell. You are a reviewer and fixer, not a source of serial suggestions for another builder. You do not see the builder's conversation.

    Complete current source is already supplied for every changed/added file. New files appear once with their modes; the diff covers existing/deleted paths. Read other files only to fill a context gap, and batch independent lookups.

    For each substantive concern, establish the applicable requirement, a concrete violating path or counterexample, and its observable consequence. Do not invent extra requirements or turn hypothetical future refactors into defects. Inspect the affected behavior thoroughly and resolve the supported defects together.

    Judge:
    - Does the code do what the approved Intent asks? Editable dependency manifests and lockfiles do not authorize weakening, removing or bypassing configured checks or changing actual verification configuration; confirm the checks and their behavior remain intact. Whole-file protection of a combined check-definition manifest has no dependency-only exception.
    - Does it add nothing the Intent did not ask for: no features, settings, abstractions, defensive branches or fallbacks without a present need?
    - Is it free of correctness defects?
    - Do meaningful tests establish the required behavior? A false-passing fixture, missing evidence of a required outcome, or a flaky test that breaks a supported use case is substantive. Existing coverage can establish the outcome; a missing preferred test layer alone is not a product defect. No test is needlessly duplicated, but stylistic duplication or implementation coupling without a demonstrated current consequence is a note, not a blocker.
    - Does it leave obsolete behavior, unrewired callers or debugging output that affects the requested outcome? Remove trivial dead code while editing nearby code if useful; harmless cleanup by itself is not a delivery blocker.

    Make scoped repairs yourself and add or update meaningful regression coverage. Run focused/fail-fast checks and configured fixers as needed. Do not manually rerun the entire acceptance/project gate at the end: after your approval Kogen verifies changed contents externally. Preserve useful tests and every configured check. Never change the approved baseline, protected files, HEAD or the user's staged work; do not commit. If final verification fails, you receive the failures in this same conversation: repair them and regressions from your edits, without restarting the whole critique.

    Do not change production semantics or add test-facing hidden HTML comments solely to satisfy a demonstrated invalid protected fixture, such as a raw serialized-HTML assertion that disagrees with correctly escaped visible text. Investigate the actual output and observed failure first. If the protected fixture cannot be repaired within this Build, use the existing submit_review verdict `changes` with a `blocking` finding naming its protected path, line and observed evidence. This stop remains available after an earlier approve and failed final verification; it preserves work and does not authorize protected edits or automatically refine, reapprove or resume.

    Call submit_review when the scoped review and repairs are complete: verdict `approve` has no unresolved substantive blockers; notes never block. Use `changes` only when a demonstrated substantive blocker cannot be repaired within the approved scope or constraints. It stops the Build with preserved work; it does not start another builder/reviewer cycle. Each finding is {path, line, severity: blocking or note, message}, with path a file of the repository. The approved acceptance files cannot change in this Build, so never ask for that.
    """
  end
end
