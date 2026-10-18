defmodule Kogen.Review do
  @moduledoc """
  The blocking review (chapter 06): after a green pass, a fresh request to `models.review` with
  the Intent, the full diff against the start HEAD, the full text of every changed file and the
  check results, plus read-only file tools and `submit_review`. It never sees the builder's
  conversation. An invalid verdict goes back once; a second one ends the Build.
  """
  alias Kogen.{Bridge, Build, Error, Git, Intent, Run, Shape, Snapshot, Tools, Usage}

  def run(b, pass) do
    n = b.review + 1
    b = %{b | review: n}
    Bridge.progress("kogen: reviewing (review #{n})")
    role = b.config.models["review"]
    input = [%{"role" => "user", "content" => material(b, pass)}]
    tools = Tools.defs(~w(read_file list_files search_text)) ++ [submit_def()]
    {b, verdict, usage} = converse(b, role, input, tools, 0, Usage.zero())
    review = Map.merge(verdict, %{n: n, verdict: verdict.verdict})
    blocking = Enum.count(verdict.findings, &(&1["severity"] == "blocking"))
    Bridge.progress("kogen: review #{n}: #{verdict.verdict}, #{blocking} blocking")

    Run.write(b.run, "review-#{n}.json", %{
      "model" => role.model,
      "effort" => role.effort,
      "usage" => usage,
      "verdict" => verdict.verdict,
      "findings" => verdict.findings
    })

    Run.log(b.run, %{
      "event" => "review",
      "review" => n,
      "pass" => pass.n,
      "verdict" => verdict.verdict,
      "findings" => verdict.findings
    })

    b = %{b | last_review: review}
    {String.to_atom(verdict.verdict), b, review}
  end

  defp converse(b, role, input, tools, invalid, usage) do
    resp = Build.request(b, "review", role, instructions(), input, tools)
    usage = Usage.add(usage, resp.usage)
    b = %{b | usage: Usage.add(b.usage, resp.usage)}
    calls = for %{"type" => "function_call"} = c <- resp.items, do: c
    input = input ++ (Enum.map(resp.items, &Shape.replay_item/1) |> Enum.reject(&is_nil/1))
    ctx = %{root: b.root, protected: [], tools: ~w(read_file list_files search_text)}

    {outputs, verdict} =
      Enum.reduce(calls, {[], nil}, fn call, {outs, verdict} ->
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
              "arguments" => call["arguments"]
            })

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
        {b, v, usage}
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

    texts =
      Enum.map_join(files, "\n", fn p ->
        case Git.run(b.root, ["show", "#{pass.tree}:#{p}"]) do
          {text, 0} ->
            if String.valid?(text) and not String.contains?(text, <<0>>),
              do: "--- #{p}\n#{text}",
              else: "--- #{p} (binary)"

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

    # Diff against the start HEAD #{String.slice(b.start, 0, 8)}

    #{Snapshot.diff(b.root, b.start, pass.tree)}
    # Full text of every changed or added file

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
    You review code that another model wrote to implement an approved Intent in this repository. Every check already passed; your review decides whether the change is committed. You cannot run commands or edit files; you may read any file of the repository with read_file, list_files and search_text.

    Judge:
    - Does the code do what the approved Intent asks? Editable dependency manifests and lockfiles do not authorize weakening, removing or bypassing configured checks or changing actual verification configuration; confirm the checks and their behavior remain intact. Whole-file protection of a combined check-definition manifest has no dependency-only exception.
    - Does it add nothing the Intent did not ask for: no features, settings, abstractions, defensive branches or fallbacks without a present need?
    - Is it free of correctness defects?
    - Do the tests follow the testing rules: every rule in the Intent's `## Tests` has its test, no test is needlessly duplicated, and no test is coupled to implementation details? Each miss is a blocking finding.
    - Does it leave no obsolete code path, dead code, unrewired caller or debugging output behind, in the requested change and its affected execution paths, including relevant unchanged callers?

    Call submit_review once with verdict `approve` (no blocking findings) or `changes` (at least one blocking finding). Each finding is {path, line, severity: blocking or note, message}, with path a file of the repository. Use blocking only for problems that must be fixed before the commit; notes never block. The approved acceptance files cannot change in this Build, so never ask for that.
    """
  end
end
