defmodule Kogen.ShapingAudit.JevLayer do
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting
  @moduledoc """
  The Shaping audit's Jev layer: advisory contract questions over the Draft,
  the question gate (who answers a `## Ask the Shaper` entry or an auditor
  finding), and the fix-check of "fixed" auditor findings.

  Every request goes through `Kogen.Jev.ask/3`, the same Keychain item and
  transport selection as the Build handoff. Requests carry only the risk
  `privacy-boundary` allowlist: scenario contract text, `proof.offline`,
  Outcome/Non-goals, `questions.md` entries, the settled list, the paid
  observation and bounded `HEAD` citation excerpts — never a diff,
  working-tree bytes, `risks.yaml`, `approval`, `references.yaml` or
  `evidence/`.

  In the `:asking` state only the question gate runs, over `## Ask the
  Shaper` entries. In `:autonomous` state the gate instead routes every
  auditor finding, the fix-check runs over "fixed" auditor findings, and the
  14 advisory contract questions run over the Draft. Any failure other than
  a retried 429 makes the whole layer `unavailable`, with one scope
  `environment` finding naming the reason and no partial finding.
  """

  alias Kogen.Jev
  alias Kogen.ShapingAudit.Finding
  alias Kogen.ShapingAudit.Questions

  @questions_path "priv/kogen/shaping_audit/questions-v1.json"
  @gate_path "priv/kogen/shaping_audit/question-gate-v1.json"
  @settled_path "priv/kogen/shaping_audit/settled.json"

  @max_item_bytes 16 * 1024
  @max_request_bytes 64 * 1024
  @max_concurrency 4
  @default_deadline_ms 60_000
  @citation_max_lines 40

  @doc "The parsed shipped question-set-v1 table (14 entries + fix-check)."
  def questions_table, do: @questions_path |> File.read!() |> Jason.decode!()

  @doc "The parsed shipped question-gate-v1 definition."
  def gate_table, do: @gate_path |> File.read!() |> Jason.decode!()

  @doc "The parsed shipped settled-decision paraphrases (`{id, text, source}`)."
  def settled_table, do: @settled_path |> File.read!() |> Jason.decode!()

  @doc """
  Runs the Jev layer. `findings` is every finding raised so far by the
  deterministic and auditor layers (this layer sets `"route"` on the
  auditor ones and may set `"still_open"`). Returns
  `%{"status", "reason", "findings", "routed_findings", "requests",
  "answers", "routes"}`.
  """
  @spec run(map(), [map()]) :: map()
  def run(ctx, findings) do
    deadline_ms = Keyword.get(ctx[:opts] || [], :jev_deadline_ms, @default_deadline_ms)
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    case Jev.key_present(jev_opts(ctx)) do
      {:error, reason} ->
        unavailable(findings, reason)

      :ok ->
        case ctx.state do
          :asking -> run_asking(ctx, deadline, deadline_ms)
          :autonomous -> run_autonomous(ctx, findings, deadline, deadline_ms)
        end
    end
  end

  # ------------------------------------------------------------- asking ---

  defp run_asking(ctx, deadline, deadline_ms) do
    settled = settled_list(ctx)
    entries = Questions.entries(ctx.questions, "Ask the Shaper")
    jobs = Enum.map(entries, fn entry -> fn -> gate_ask_entry(ctx, entry, settled) end end)

    case run_jobs(jobs, deadline, deadline_ms) do
      {:ok, results} ->
        requests = Enum.flat_map(results, & &1.requests)
        answers = Enum.flat_map(results, & &1.answers)

        %{
          "status" => "ok",
          "reason" => nil,
          "findings" => Enum.flat_map(results, & &1.findings),
          "routed_findings" => [],
          "requests" => Enum.sort(requests),
          "answers" => answer_map(requests, answers),
          "routes" => Enum.flat_map(results, & &1.routes)
        }

      {:error, reason} ->
        unavailable([], reason)
    end
  end

  defp gate_ask_entry(ctx, entry, settled) do
    item_id = "ask-entry-#{entry.number || slug(entry.title)}"
    item_text = entry.text

    case guard_item(item_text) do
      {:error, %{finding: finding}} ->
        %{findings: [finding], requests: [], answers: [], routes: []}

      :ok ->
        with {:ok, gate_result} <- gate_request(ctx, item_id, item_text, settled),
             {:ok, route} <- resolve_route(ctx, item_id, item_text, gate_result, settled) do
          finding = ask_gate_finding(entry, route)

          %{
            findings: List.wrap(finding),
            requests: gate_result.requests ++ route.requests,
            answers: gate_result.answers_list ++ route.answers,
            routes: [
              route_entry("question #{entry.number || slug(entry.title)}", route, gate_result)
            ]
          }
        end
    end
  end

  defp ask_gate_finding(entry, %{route: "cite", settled_by: id}) do
    Finding.new("question-already-settled", subject(entry), %{
      "layer" => "jev",
      "severity" => "blocking",
      "scope" => "draft",
      "disputable" => true,
      "route" => "cite",
      "paths" => ["questions.md"],
      "message" =>
        "question #{subject(entry)} is already settled by `#{id}` — move it under ## Settled with the citation."
    })
  end

  defp ask_gate_finding(entry, %{route: "controller"}) do
    Finding.new("technical-question-to-shaper", subject(entry), %{
      "layer" => "jev",
      "severity" => "blocking",
      "scope" => "draft",
      "disputable" => true,
      "route" => "controller",
      "paths" => ["questions.md"],
      "message" =>
        "question #{subject(entry)} is technical: decide it and record it under ## Settled."
    })
  end

  defp ask_gate_finding(_entry, %{route: "shaper"}), do: nil

  defp subject(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  defp subject(entry), do: slug(entry.title)

  defp slug(text), do: text |> String.slice(0, 40) |> String.replace(~r/\s+/, "-")

  # --------------------------------------------------------- autonomous ---

  defp run_autonomous(ctx, findings, deadline, deadline_ms) do
    auditor_findings = Enum.filter(findings, &(&1["layer"] == "auditor"))
    settled = settled_list(ctx)

    routing_jobs =
      Enum.map(auditor_findings, fn finding ->
        fn -> route_and_fix_check(ctx, finding, settled) end
      end)

    contract_jobs = contract_question_jobs(ctx)

    case run_jobs(routing_jobs ++ contract_jobs, deadline, deadline_ms) do
      {:ok, results} ->
        {routed_results, contract_results} = Enum.split(results, length(auditor_findings))

        requests =
          Enum.flat_map(routed_results, & &1.requests) ++
            Enum.flat_map(contract_results, & &1.requests)

        answers =
          Enum.flat_map(routed_results, & &1.answers) ++
            Enum.flat_map(contract_results, & &1.answers)

        routed_findings =
          routed_results
          |> Enum.zip(auditor_findings)
          |> Enum.map(fn {result, _finding} -> result.finding end)

        %{
          "status" => "ok",
          "reason" => nil,
          "findings" => Enum.flat_map(contract_results, & &1.findings),
          "routed_findings" => routed_findings,
          "requests" => Enum.sort(requests),
          "answers" => answer_map(requests, answers),
          "routes" => Enum.flat_map(routed_results, & &1.routes)
        }

      {:error, reason} ->
        unavailable(findings, reason)
    end
  end

  defp route_and_fix_check(ctx, finding, settled) do
    item_id = "auditor-#{finding["id"]}"
    item_text = auditor_item_text(finding)

    with :ok <- guard_item(item_text),
         {:ok, gate_result} <- gate_request(ctx, item_id, item_text, settled),
         {:ok, route} <- resolve_route(ctx, item_id, item_text, gate_result, settled) do
      routed = annotate_route(finding, route)

      case maybe_fix_check(ctx, routed) do
        {:error, reason} ->
          {:error, reason}

        {:ok, fixed_result} ->
          %{
            finding: fixed_result.finding,
            requests: gate_result.requests ++ route.requests ++ fixed_result.requests,
            answers: gate_result.answers_list ++ route.answers ++ fixed_result.answers,
            routes: [route_entry(finding["id"], route, gate_result)]
          }
      end
    else
      {:error, %{finding: size_finding}} ->
        %{
          finding: Map.put(finding, "route", nil),
          requests: [],
          answers: [size_finding],
          routes: []
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp annotate_route(finding, %{route: "shaper"}) do
    finding
    |> Map.put("route", "shaper")
    |> Map.update("message", "", fn message ->
      message <>
        " (routed to the Shaper: in the autonomous state this becomes a listed assumption, never a question.)"
    end)
  end

  defp annotate_route(finding, %{route: route}), do: Map.put(finding, "route", route)

  defp maybe_fix_check(ctx, %{"disposition" => %{"kind" => "fixed"}} = finding) do
    case disposition_scenario(ctx, finding) do
      nil ->
        {:ok, %{finding: finding, requests: [], answers: []}}

      scenario ->
        case guard_item(Jason.encode!(scenario)) do
          {:error, %{finding: _size_finding}} ->
            {:ok, %{finding: finding, requests: [], answers: []}}

          :ok ->
            with {:ok, result} <- fix_check_request(ctx, finding, scenario) do
              {:ok, fix_check_result(finding, result)}
            end
        end
    end
  end

  defp maybe_fix_check(_ctx, finding), do: {:ok, %{finding: finding, requests: [], answers: []}}

  defp fix_check_result(finding, %{"answers" => answers} = result) do
    answer = answers["fix-check"]

    still_open =
      (answer["choice"] == "not_addressed" and answer["confidence"] >= 0.6) or
        answer["choice"] == "partly"

    finding = Map.put(finding, "still_open", still_open)

    %{finding: finding, requests: [result["request"]["sha256"]], answers: [answers]}
  end

  defp fix_check_request(ctx, finding, scenario) do
    state = %{
      "finding" => %{
        "id" => finding["id"],
        "rule" => finding["rule"],
        "message" => finding["message"]
      },
      "scenario" => %{
        "id" => scenario["id"],
        "given" => scenario["given"],
        "when" => scenario["when"],
        "then" => scenario["then"],
        "wrong_result" => scenario["wrong_result"],
        "evidence" => scenario["evidence"]
      }
    }

    questions_table = questions_table()
    fix_check = questions_table["fix-check"]

    questions = %{
      "fix-check" => %{
        "type" => "choice",
        "instructions" => get_in(fix_check, ["question", "instructions"]),
        "criteria" => get_in(fix_check, ["question", "criteria"])
      }
    }

    Jev.ask(state, questions, jev_opts(ctx))
  end

  defp disposition_scenario(ctx, %{"disposition" => %{"reason" => reason}})
       when is_binary(reason) do
    scenario_named_in(ctx, reason)
  end

  defp disposition_scenario(ctx, %{"disposition" => %{"text" => text}})
       when is_binary(text),
       do: scenario_named_in(ctx, text)

  defp disposition_scenario(_ctx, _finding), do: nil

  defp scenario_named_in(ctx, text) do
    Enum.find(ctx.scenarios || [], fn scenario ->
      id = scenario["id"]

      is_binary(id) and
        Regex.match?(~r/(?<![A-Za-z0-9_-])#{Regex.escape(id)}(?![A-Za-z0-9_-])/, text)
    end)
  end

  defp auditor_item_text(finding) do
    "#{finding["rule"]}: #{finding["message"]}"
  end

  # ---------------------------------------------------------- the gate ---

  defp gate_request(ctx, item_id, item_text, settled) do
    gate = gate_table()

    state = %{
      "item" => item_text,
      "settled" => Enum.map(settled, &Map.take(&1, ["id", "text"]))
    }

    questions = %{
      "gate" => gate["questions"]["gate"],
      "settled_by" =>
        Map.put(gate["questions"]["settled_by"], "criteria", settled_by_criteria(settled))
    }

    case guard_request(item_id, Jev.ask_body(state, questions)) do
      {:error, %{finding: finding}} ->
        {:error, finding["message"]}

      :ok ->
        case ask_in_vocabulary(state, questions, jev_opts(ctx)) do
          {:error, reason} ->
            {:error, reason}

          {:ok, result} ->
            {:ok,
             %{
               answers: result["answers"],
               requests: [result["request"]["sha256"]],
               answers_list: [result["answers"]]
             }}
        end
    end
  end

  # Jev occasionally answers a choice with an option from another calibrated
  # question it knows (live: `no_objection`, from `Kogen.Jev`'s objection
  # set, for the gate). `Kogen.Jev` rejects such an answer strictly; the
  # gate re-asks the identical request once, and a second answer outside
  # the sent options still fails the layer.
  @out_of_vocabulary_retries 1

  defp ask_in_vocabulary(state, questions, opts, retries \\ @out_of_vocabulary_retries) do
    case Jev.ask(state, questions, opts) do
      {:error, reason} = error ->
        if retries > 0 and String.contains?(reason, "was not sent)"),
          do: ask_in_vocabulary(state, questions, opts, retries - 1),
          else: error

      {:ok, result} ->
        {:ok, result}
    end
  end

  defp settled_by_criteria(settled) do
    Map.new(settled, fn decision -> {decision["id"], decision["text"]} end)
    |> Map.put("none", "No listed decision answers it.")
  end

  defp resolve_route(ctx, item_id, item_text, gate_result, settled) do
    gate_answer = gate_result.answers["gate"]
    by_answer = gate_result.answers["settled_by"]

    probabilities =
      gate_answer["probabilities"] || %{gate_answer["choice"] => gate_answer["confidence"]}

    already_settled = Map.get(probabilities, "already_settled", 0)
    technical = Map.get(probabilities, "technical", 0)
    by_confidence = (by_answer && by_answer["confidence"]) || 0
    by_choice = by_answer && by_answer["choice"]

    if already_settled >= 0.8 and by_choice not in [nil, "none"] and by_confidence >= 0.8 do
      resolve_settled_route(ctx, item_id, item_text, settled, by_choice, technical)
    else
      {:ok,
       %{
         route: fallback_route(technical),
         settled_by: nil,
         confirm: nil,
         requests: [],
         answers: []
       }}
    end
  end

  defp resolve_settled_route(ctx, item_id, item_text, settled, by_choice, technical) do
    decision = Enum.find(settled, &(&1["id"] == by_choice))

    case confirm_request(ctx, item_id, item_text, by_choice, decision) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %{confirm: confirm, requests: requests, answers: answers}} ->
        route = if confirm >= 0.6, do: "cite", else: fallback_route(technical)

        {:ok,
         %{
           route: route,
           settled_by: by_choice,
           confirm: confirm,
           requests: requests,
           answers: answers
         }}
    end
  end

  defp fallback_route(technical) when technical >= 0.5, do: "controller"
  defp fallback_route(_technical), do: "shaper"

  defp route_entry(item, route, gate_result) do
    gate = gate_table()

    %{
      "item" => item,
      "route" => route.route,
      "settled_by" => route.settled_by,
      "distributions" => %{
        "gate" => gate_result.answers["gate"],
        "settled_by" => gate_result.answers["settled_by"],
        "confirm" => route.confirm
      },
      "model" => gate["model"],
      "wording_version" => gate["version"]
    }
  end

  defp confirm_request(ctx, item_id, item_text, decision_id, decision) do
    gate = gate_table()

    state = %{
      "item" => item_text,
      "decision" => %{"id" => decision_id, "text" => decision && decision["text"]}
    }

    questions = %{"confirm" => gate["questions"]["confirm"]}

    case guard_request("#{item_id}-confirm", Jev.ask_body(state, questions)) do
      {:error, %{finding: _finding}} ->
        {:ok, %{confirm: 0, requests: [], answers: []}}

      :ok ->
        case Jev.ask(state, questions, jev_opts(ctx)) do
          {:error, reason} ->
            {:error, reason}

          {:ok, result} ->
            confirm = result["answers"]["confirm"]["noul"]

            {:ok,
             %{
               confirm: confirm,
               requests: [result["request"]["sha256"]],
               answers: [result["answers"]]
             }}
        end
    end
  end

  defp settled_list(ctx) do
    from_priv = settled_table()["entries"]
    from_package = Questions.entries(ctx.questions, "Settled")

    package_entries =
      Enum.map(from_package, fn entry ->
        %{"id" => "package-#{entry.number || slug(entry.title)}", "text" => entry.text}
      end)

    from_priv ++ package_entries
  end

  # -------------------------------------------------- 14 contract Qs ----

  defp contract_question_jobs(ctx) do
    non_goals = list_section(ctx, "Non-goals|Appetite and non-goals")

    scenario_jobs =
      Enum.flat_map(ctx.scenarios || [], fn scenario ->
        [
          fn -> scenario_clause_job(ctx, scenario) end,
          fn -> scenario_caught_job(ctx, scenario) end,
          fn -> scenario_provider_job(ctx, scenario) end,
          fn -> scenario_nongoal_job(ctx, scenario, non_goals) end
        ]
      end)

    scenario_jobs ++
      [
        fn -> outcome_coverage_job(ctx) end,
        fn -> question_provenance_job(ctx) end,
        fn -> citation_job(ctx) end
      ]
  end

  defp entries_table, do: Map.new(questions_table()["entries"], &{&1["id"], &1})

  defp split_clauses(text), do: split_on(text, ~r/(?<=[.;])\s+(?=[A-Z`])/)

  defp split_alternatives(text),
    do:
      split_on(text, ~r/;\s*(?:or\s+)?|\.\s+(?:Or\s+)?/)
      |> Enum.map(&String.trim_trailing(&1, "."))

  defp evidence_items(text), do: split_on(text, ~r/;\s*|\.\s+/)

  defp split_on(nil, _regex), do: []

  defp split_on(text, regex) do
    text
    |> normalize()
    |> String.split(regex)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) > 3))
  end

  defp normalize(nil), do: ""
  defp normalize(text), do: text |> to_string() |> String.split() |> Enum.join(" ")

  defp scenario_clause_job(ctx, scenario) do
    sid = scenario["id"]
    clauses = split_clauses(scenario["then"])
    alts = split_alternatives(scenario["wrong_result"])
    table = entries_table()

    state = %{
      "then_clauses" => indexed(clauses, "c"),
      "wrong_result_alternatives" => indexed(alts, "w")
    }

    questions =
      clause_questions(clauses, table) |> Map.merge(plausible_questions(alts, table))

    if map_size(questions) == 0 do
      %{findings: [], requests: [], answers: []}
    else
      send_request("#{sid}-clauses", clauses ++ alts, state, questions, ctx, fn result ->
        result_of(clause_findings(sid, clauses, alts, result["answers"], table), result)
      end)
    end
  end

  defp clause_questions(clauses, table) do
    Enum.reduce(Enum.with_index(clauses), %{}, fn {_c, i}, acc ->
      acc
      |> Map.put("kind:c#{i}", clause_question(table["clause-kind"], "then_clauses.c#{i}"))
      |> Map.put(
        "asserted:c#{i}",
        clause_question(table["clause-asserted"], "then_clauses.c#{i}")
      )
      |> Map.put("timeout:c#{i}", noul_question(table["clause-timeout"]))
      |> Map.put("effort:c#{i}", noul_question(table["clause-effort"]))
      |> Map.put("weaken:c#{i}", noul_question(table["clause-weaken"]))
    end)
  end

  defp plausible_questions(alts, table) do
    Enum.reduce(Enum.with_index(alts), %{}, fn {_w, j}, acc ->
      Map.put(
        acc,
        "plaus:w#{j}",
        clause_question(table["alternative-plausible"], "wrong_result_alternatives.w#{j}")
      )
    end)
  end

  defp indexed(list, prefix) do
    list |> Enum.with_index() |> Map.new(fn {v, i} -> {"#{prefix}#{i}", v} end)
  end

  defp clause_question(entry, ref) do
    %{
      "type" => "choice",
      "instructions" => %{
        "task" =>
          String.replace(entry["question"]["instructions"]["task"], ~r/`[^`]+`/, "`#{ref}`",
            global: false
          ),
        "rules" => entry["question"]["instructions"]["rules"]
      },
      "criteria" => entry["question"]["criteria"]
    }
  end

  defp noul_question(entry) do
    %{
      "type" => "noul",
      "instructions" => entry["question"]["instructions"],
      "criteria" => entry["question"]["criteria"]
    }
  end

  defp clause_findings(sid, clauses, alts, answers, table) do
    kind_findings =
      clauses
      |> Enum.with_index()
      |> Enum.flat_map(fn {clause, i} ->
        kind = answers["kind:c#{i}"]
        asserted = answers["asserted:c#{i}"]

        List.flatten([
          gated_finding(
            kind,
            "unobservable",
            0.80,
            "then-unobservable",
            sid,
            "c#{i}",
            clause,
            table
          ),
          if(kind["choice"] != "not_behaviour",
            do:
              gated_finding(
                asserted,
                "not_described",
                0.80,
                "then-without-described-proof",
                sid,
                "c#{i}",
                clause,
                table
              ),
            else: []
          ),
          hard_rule_finding(sid, i, clause, answers)
        ])
      end)

    plaus_findings =
      alts
      |> Enum.with_index()
      |> Enum.flat_map(fn {alt, j} ->
        p = answers["plaus:w#{j}"]

        if p["choice"] in ["implausible", "not_a_mistake"] and p["confidence"] >= 0.80 do
          [
            wrong_result_finding(
              "wrong-result-implausible",
              sid,
              j,
              alt,
              table["alternative-plausible"],
              p
            )
          ]
        else
          []
        end
      end)

    kind_findings ++ plaus_findings
  end

  defp hard_rule_finding(sid, i, clause, answers) do
    hits =
      [
        {"timeout", "hard-rule-timeout-raised"},
        {"effort", "hard-rule-effort-lowered"},
        {"weaken", "hard-rule-check-loosened"}
      ]
      |> Enum.flat_map(fn {key, rule} ->
        answer = answers["#{key}:c#{i}"]

        if answer && answer["noul"] >= 0.75 do
          [
            Finding.new(rule, "#{sid}-c#{i}", %{
              "layer" => "jev",
              "severity" => "advisory",
              "scope" => "draft",
              "scenario" => sid,
              "message" =>
                "then clause `#{String.slice(clause, 0, 200)}` of scenario `#{sid}` looks like it #{describe(rule)} (Jev noul #{answer["noul"]})."
            })
          ]
        else
          []
        end
      end)

    hits
  end

  defp describe("hard-rule-timeout-raised"), do: "raises or loosens a timeout"
  defp describe("hard-rule-effort-lowered"), do: "lowers a model's reasoning effort"
  defp describe("hard-rule-check-loosened"), do: "loosens an existing check"

  defp gated_finding(answer, choice, threshold, rule, sid, subject, text, table) do
    if answer["choice"] == choice and answer["confidence"] >= threshold do
      [
        Finding.new(rule, "#{sid}-#{subject}", %{
          "layer" => "jev",
          "severity" => "advisory",
          "scope" => "draft",
          "scenario" => sid,
          "message" =>
            "#{table[String.replace(rule, "then-", "clause-")]["question"]["instructions"]["task"] |> rule_message()} `#{String.slice(text, 0, 200)}` (Jev #{choice}, confidence #{answer["confidence"]})."
        })
      ]
    else
      []
    end
  end

  defp rule_message(_task), do: "the Jev contract question flags"

  defp wrong_result_finding(rule, sid, j, alt, entry, answer) do
    Finding.new(rule, "#{sid}-w#{j}", %{
      "layer" => "jev",
      "severity" => "advisory",
      "scope" => "draft",
      "scenario" => sid,
      "message" =>
        "wrong_result alternative `#{String.slice(alt, 0, 200)}` of scenario `#{sid}` #{entry["finding"]} (Jev #{answer["choice"]}, confidence #{answer["confidence"]})."
    })
  end

  defp scenario_caught_job(ctx, scenario) do
    sid = scenario["id"]
    alts = split_alternatives(scenario["wrong_result"])
    items = evidence_items(scenario["evidence"])

    if alts == [] or items == [] do
      %{findings: [], requests: [], answers: []}
    else
      state = %{
        "then" => normalize(scenario["then"]),
        "evidence" => normalize(scenario["evidence"]),
        "offline_selectors" => (scenario["proof"] || %{})["offline"],
        "evidence_items" => indexed(items, "e"),
        "wrong_behaviours" => indexed(alts, "w")
      }

      questions = caught_questions(alts, items)

      send_request("#{sid}-caught", alts ++ items, state, questions, ctx, fn result ->
        result_of(caught_findings(sid, alts, result["answers"]), result)
      end)
    end
  end

  defp caught_questions(alts, items) do
    criteria =
      Map.new(Enum.with_index(items), fn {_i, k} ->
        {"e#{k}", "Evidence item e#{k} checks it."}
      end)
      |> Map.put("none", "No evidence item checks the thing it gets wrong.")

    Enum.reduce(Enum.with_index(alts), %{}, fn {_w, j}, acc ->
      acc
      |> Map.put("caught_noul:w#{j}", %{
        "type" => "noul",
        "instructions" =>
          "Would a test or control that `evidence` explicitly describes fail if the implementation behaved as `wrong_behaviours.w#{j}`?",
        "criteria" => %{
          "true" =>
            "`evidence` names an assertion, negative control or case that directly checks the thing it gets wrong.",
          "false" =>
            "`evidence` names no assertion or case that checks it; a general or happy-path test does not count."
        }
      })
      |> Map.put("caught_choice:w#{j}", %{
        "type" => "choice",
        "instructions" => %{
          "task" =>
            "Which item in `evidence_items` would fail if the implementation behaved as `wrong_behaviours.w#{j}`?",
          "rules" => [
            "Pick an item only if it explicitly checks the thing that behaviour gets wrong.",
            "A general or happy-path test does not count; choose none."
          ]
        },
        "criteria" => criteria
      })
    end)
  end

  defp caught_findings(sid, alts, answers) do
    alts
    |> Enum.with_index()
    |> Enum.flat_map(fn {alt, j} ->
      noul = answers["caught_noul:w#{j}"]["noul"]
      choice_answer = answers["caught_choice:w#{j}"]
      none? = choice_answer["choice"] == "none" and choice_answer["confidence"] >= 0.50
      low? = noul < 0.60

      if none? and low? do
        [
          Finding.new("wrong-result-not-caught", "#{sid}-w#{j}", %{
            "layer" => "jev",
            "severity" => "advisory",
            "scope" => "draft",
            "scenario" => sid,
            "message" =>
              "No evidence item catches wrong_result alternative `#{String.slice(alt, 0, 200)}` of scenario `#{sid}` (Jev caught_choice #{choice_answer["choice"]} #{choice_answer["confidence"]}, caught_noul #{noul})."
          })
        ]
      else
        []
      end
    end)
  end

  defp scenario_provider_job(ctx, scenario) do
    proof = scenario["proof"] || %{}

    if proof["paid_target"] in [nil, "none"] do
      clause_provider_job(ctx, scenario)
    else
      paid_observation_job(ctx, scenario)
    end
  end

  defp paid_observation_job(ctx, scenario) do
    sid = scenario["id"]
    reason = normalize((scenario["proof"] || %{})["paid_reason"])

    case Regex.run(~r/observation:\s*(.*?);\s*offline-limit/, reason) do
      [_, observation] -> paid_observation_request(ctx, sid, observation)
      nil -> %{findings: [], requests: [], answers: []}
    end
  end

  defp paid_observation_request(ctx, sid, observation) do
    state = %{"observation" => observation}

    questions = %{
      "o" => %{
        "type" => "choice",
        "instructions" => %{
          "task" => "Is `observation` something only a real AI provider run can show?",
          "rules" => [
            "provider_only: it is about what a real model or real provider runtime does.",
            "offline: it is about Kogen's own outputs that an offline test with fakes can check."
          ]
        },
        "criteria" => %{
          "provider_only" => "Only a real provider run can show it.",
          "offline" => "An offline test with fakes can check it."
        }
      }
    }

    send_request("#{sid}-paid", [observation], state, questions, ctx, fn result ->
      result_of(paid_observation_findings(sid, observation, result["answers"]["o"]), result)
    end)
  end

  defp paid_observation_findings(sid, observation, answer) do
    if answer["choice"] == "offline" and answer["confidence"] >= 0.80 do
      [
        Finding.new("paid-observation-offline-checkable", sid, %{
          "layer" => "jev",
          "severity" => "advisory",
          "scope" => "draft",
          "scenario" => sid,
          "message" =>
            "The paid observation `#{String.slice(observation, 0, 200)}` of scenario `#{sid}` looks offline-checkable (Jev confidence #{answer["confidence"]})."
        })
      ]
    else
      []
    end
  end

  defp clause_provider_job(ctx, scenario) do
    sid = scenario["id"]
    clauses = split_clauses(scenario["then"])

    if clauses == [] do
      %{findings: [], requests: [], answers: []}
    else
      state = %{
        "given" => normalize(scenario["given"]),
        "when" => normalize(scenario["when"]),
        "then_clauses" => indexed(clauses, "c")
      }

      questions = provider_questions(clauses)

      send_request("#{sid}-provider", clauses, state, questions, ctx, fn result ->
        result_of(provider_findings(sid, clauses, result["answers"]), result)
      end)
    end
  end

  defp provider_questions(clauses) do
    Enum.reduce(Enum.with_index(clauses), %{}, fn {_c, i}, acc ->
      Map.put(acc, "pc:c#{i}", %{
        "type" => "choice",
        "instructions" => %{
          "task" =>
            "Can clause `then_clauses.c#{i}` be checked by an offline test with fake AI harnesses?",
          "rules" => [
            "Kogen's own code is checkable offline with fakes, even when the code is about a provider.",
            "Only what a real model or real provider runtime itself does needs a provider run."
          ]
        },
        "criteria" => %{
          "offline" => "An offline test with fakes can check it.",
          "provider_only" => "It states what a real model or real provider runtime does."
        }
      })
    end)
  end

  defp provider_findings(sid, clauses, answers) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, i} -> provider_finding(sid, clause, i, answers["pc:c#{i}"]) end)
  end

  defp provider_finding(sid, clause, i, answer) do
    if answer["choice"] == "provider_only" and answer["confidence"] >= 0.90 do
      [
        Finding.new("provider-behaviour-in-offline-scenario", "#{sid}-c#{i}", %{
          "layer" => "jev",
          "severity" => "advisory",
          "scope" => "draft",
          "scenario" => sid,
          "message" =>
            "then clause `#{String.slice(clause, 0, 200)}` of offline scenario `#{sid}` states provider behaviour (Jev confidence #{answer["confidence"]})."
        })
      ]
    else
      []
    end
  end

  defp scenario_nongoal_job(ctx, scenario, non_goals) do
    sid = scenario["id"]

    if non_goals == [] do
      %{findings: [], requests: [], answers: []}
    else
      state = %{
        "scenario_then" => normalize(scenario["then"]),
        "non_goals" => indexed(non_goals, "n")
      }

      questions = %{"leak" => nongoal_question(non_goals)}

      send_request(
        "#{sid}-nongoal",
        [normalize(scenario["then"])],
        state,
        questions,
        ctx,
        fn result ->
          result_of(nongoal_findings(sid, non_goals, result["answers"]["leak"]), result)
        end
      )
    end
  end

  defp nongoal_question(non_goals) do
    criteria =
      non_goals
      |> Enum.with_index()
      |> Map.new(fn {_n, i} -> {"n#{i}", "Non-goal n#{i}."} end)
      |> Map.put("none", "The scenario requires no listed non-goal.")

    %{
      "type" => "choice",
      "instructions" => %{
        "task" => "Which non-goal in `non_goals`, if any, does `scenario_then` require doing?",
        "rules" => [
          "Choose a non-goal only when the scenario requires the excluded behaviour itself.",
          "Mentioning a related topic, or promising not to do it, is none."
        ]
      },
      "criteria" => criteria
    }
  end

  defp nongoal_findings(sid, non_goals, answer) do
    if answer["choice"] != "none" and answer["confidence"] >= 0.60 do
      index = answer["choice"] |> String.trim_leading("n") |> String.to_integer()
      non_goal = Enum.at(non_goals, index)

      [
        Finding.new("non-goal-leakage", sid, %{
          "layer" => "jev",
          "severity" => "advisory",
          "scope" => "draft",
          "scenario" => sid,
          "message" =>
            "Scenario `#{sid}` looks like it requires the non-goal `#{String.slice(non_goal || "", 0, 200)}` (Jev confidence #{answer["confidence"]})."
        })
      ]
    else
      []
    end
  end

  defp outcome_coverage_job(ctx) do
    outcomes = list_section(ctx, "Outcome")
    scenarios = ctx.scenarios || []

    if outcomes == [] or scenarios == [] do
      %{findings: [], requests: [], answers: []}
    else
      scen_state =
        Map.new(scenarios, fn s -> {s["id"], String.slice(normalize(s["then"]), 0, 1500)} end)

      state = %{"outcomes" => indexed(outcomes, "o"), "scenarios" => scen_state}
      questions = outcome_coverage_questions(outcomes, scenarios)

      send_request("outcome-coverage", outcomes, state, questions, ctx, fn result ->
        result_of(outcome_coverage_findings(outcomes, result["answers"]), result)
      end)
    end
  end

  defp outcome_coverage_questions(outcomes, scenarios) do
    criteria =
      Map.new(scenarios, fn s ->
        {s["id"], "Scenario #{s["id"]} states this outcome's observable result."}
      end)
      |> Map.put("none", "No scenario states this outcome's observable result.")

    Enum.reduce(Enum.with_index(outcomes), %{}, fn {_o, i}, acc ->
      Map.put(acc, "cov:o#{i}", %{
        "type" => "choice",
        "instructions" => %{
          "task" =>
            "Which scenario in `scenarios` states the observable result of outcome `outcomes.o#{i}`?",
          "rules" => [
            "Pick the scenario whose `then` directly states this outcome's result.",
            "A scenario that only mentions the topic does not count; choose none."
          ]
        },
        "criteria" => criteria
      })
    end)
  end

  defp outcome_coverage_findings(outcomes, answers) do
    outcomes
    |> Enum.with_index()
    |> Enum.flat_map(fn {outcome, i} ->
      outcome_coverage_finding(outcome, i, answers["cov:o#{i}"])
    end)
  end

  defp outcome_coverage_finding(outcome, i, answer) do
    if answer["choice"] == "none" and answer["confidence"] >= 0.80 do
      [
        Finding.new("outcome-without-scenario", "o#{i}", %{
          "layer" => "jev",
          "severity" => "advisory",
          "scope" => "draft",
          "message" =>
            "No scenario states the observable result of Outcome item `#{String.slice(outcome, 0, 200)}` (Jev confidence #{answer["confidence"]})."
        })
      ]
    else
      []
    end
  end

  defp question_provenance_job(ctx) do
    entries =
      ((ctx.questions.sections["Ask the Shaper"] || []) ++
         (ctx.questions.sections["Settled"] || []) ++ (ctx.questions.sections["Assumed"] || []))
      |> Enum.filter(&is_integer(&1.number))

    if entries == [] do
      %{findings: [], requests: [], answers: []}
    else
      texts = Enum.map(entries, & &1.text)
      state = %{"entries" => indexed(texts, "q")}
      questions = provenance_questions(entries)

      send_request("question-provenance", texts, state, questions, ctx, fn result ->
        result_of(provenance_findings(entries, result["answers"]), result)
      end)
    end
  end

  defp provenance_questions(entries) do
    Enum.reduce(Enum.with_index(entries), %{}, fn {_e, i}, acc ->
      Map.put(acc, "prov:q#{i}", %{
        "type" => "choice",
        "instructions" => %{
          "task" => "How is question entry `entries.q#{i}` resolved?",
          "rules" => [
            "with_provenance: it states a decision and names its source, evidence, measurement, file, risk or reason.",
            "without_provenance: it states a decision but gives no source, evidence or reason.",
            "unresolved: it leaves the choice open or undecided."
          ]
        },
        "criteria" => %{
          "with_provenance" => "A decision with its source, evidence or reason.",
          "without_provenance" => "A decision with no source, evidence or reason.",
          "unresolved" => "The choice is left open."
        }
      })
    end)
  end

  defp provenance_findings(entries, answers) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, i} -> provenance_finding(entry, answers["prov:q#{i}"]) end)
  end

  defp provenance_finding(entry, answer) do
    if answer["choice"] != "with_provenance" and answer["confidence"] >= 0.80 do
      rule =
        if answer["choice"] == "unresolved",
          do: "question-unresolved",
          else: "question-without-provenance"

      [
        Finding.new(rule, "#{entry.number}", %{
          "layer" => "jev",
          "severity" => "advisory",
          "scope" => "draft",
          "paths" => ["questions.md"],
          "message" =>
            "questions.md entry #{entry.number} is #{answer["choice"]} (Jev confidence #{answer["confidence"]})."
        })
      ]
    else
      []
    end
  end

  defp citation_job(ctx) do
    claims = citation_claims(ctx)

    if claims == [] do
      %{findings: [], requests: [], answers: []}
    else
      state = %{
        "citations" =>
          Map.new(claims, fn c -> {c.id, %{"claim" => c.text, "cited_lines" => c.lines}} end)
      }

      questions = citation_questions(claims)
      texts = Enum.map(claims, & &1.text)

      send_request("citations", texts, state, questions, ctx, fn result ->
        result_of(citation_findings(claims, result["answers"]), result)
      end)
    end
  end

  defp citation_questions(claims) do
    Map.new(claims, fn c ->
      {c.id,
       %{
         "type" => "choice",
         "instructions" => %{
           "task" => "Does `citations.#{c.id}.cited_lines` support `citations.#{c.id}.claim`?",
           "rules" => [
             "Judge only from `cited_lines`; do not use outside knowledge of the repository.",
             "supported: the lines directly show the claim is true.",
             "contradicted: the lines show something incompatible with the claim.",
             "insufficient: the lines are about something else or do not settle it."
           ]
         },
         "criteria" => %{
           "supported" => "The cited lines directly show the claim is true.",
           "contradicted" => "The cited lines show something incompatible with the claim.",
           "insufficient" =>
             "The cited lines are about something else or do not settle the claim."
         }
       }}
    end)
  end

  defp citation_findings(claims, answers) do
    Enum.flat_map(claims, fn claim -> citation_claim_finding(claim, answers[claim.id]) end)
  end

  defp citation_claim_finding(_claim, %{"choice" => "supported", "confidence" => confidence})
       when confidence >= 0.85,
       do: []

  defp citation_claim_finding(claim, %{"choice" => "contradicted"} = answer),
    do: [citation_finding("citation-contradicted", claim, answer)]

  defp citation_claim_finding(claim, answer),
    do: [citation_finding("citation-insufficient", claim, answer)]

  defp citation_finding(rule, claim, answer) do
    Finding.new(rule, claim.id, %{
      "layer" => "jev",
      "severity" => "advisory",
      "scope" => "draft",
      "paths" => [claim.path],
      "message" =>
        "The cited HEAD lines of `#{claim.path}` #{String.replace(rule, "citation-", "")} the claim `#{String.slice(claim.text, 0, 160)}` (Jev #{answer["choice"]}, confidence #{answer["confidence"]})."
    })
  end

  # `Evidence:` (or `Question:`) fields of the shape `path:line`, resolved
  # against the `HEAD` materialization, never the working tree.
  defp citation_claims(ctx) do
    entries =
      (ctx.questions.sections["Assumed"] || []) ++ (ctx.questions.sections["Settled"] || [])

    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} -> citation_claim(ctx, entry, idx) end)
  end

  defp citation_claim(ctx, entry, idx) do
    value = entry.fields["Evidence"] || ""

    case Regex.run(~r/^([A-Za-z0-9_.\/~-]+):(\d+)/, String.trim(value)) do
      [_, path, line] -> citation_claim_at(ctx, entry, idx, path, String.to_integer(line))
      _ -> []
    end
  end

  defp citation_claim_at(ctx, entry, idx, path, line) do
    case materialization_lines(ctx, path, line) do
      "" -> []
      lines -> [%{id: "c#{idx}", path: path, line: line, text: entry.title, lines: lines}]
    end
  end

  defp materialization_lines(ctx, path, from_line) do
    full_path = Path.join(ctx.materialization, path)
    read = Keyword.get(ctx[:opts] || [], :read, &File.read/1)

    case read.(full_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {_line, n} -> n >= from_line end)
        |> Enum.take(@citation_max_lines)
        |> Enum.map_join("\n", fn {line, n} -> "#{n}: #{line}" end)

      {:error, _reason} ->
        ""
    end
  end

  defp list_section(ctx, title) do
    text = Map.get(ctx.files || %{}, "INTENT.md", "")

    case Regex.run(~r/^##\s+(?:#{title})[^\n]*\n(.*?)(?=^##\s|\z)/ms, to_string(text)) do
      [_, section] ->
        section
        |> String.split(~r/\n(?=- |\d+\. )/)
        |> Enum.map(&(&1 |> String.trim_leading("- ") |> String.trim() |> normalize()))
        |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  # A single ask/3 call, skipped (with an advisory finding) when its items or
  # its encoded body are over the size limit; `on_success` turns the parsed
  # result into `%{findings:, requests:, answers:}`.
  defp send_request(id, state, questions, ctx, on_success) do
    body = Jev.ask_body(state, questions)

    case guard_request(id, body) do
      {:error, %{finding: finding}} -> %{findings: [finding], requests: [], answers: []}
      :ok -> ask_and_handle(state, questions, ctx, on_success)
    end
  end

  defp send_request(id, items, state, questions, ctx, on_success) do
    case guard_items(id, items) do
      {:error, %{finding: finding}} -> %{findings: [finding], requests: [], answers: []}
      :ok -> send_request(id, state, questions, ctx, on_success)
    end
  end

  defp ask_and_handle(state, questions, ctx, on_success) do
    case Jev.ask(state, questions, jev_opts(ctx)) do
      {:error, reason} -> {:error, reason}
      {:ok, result} -> on_success.(result)
    end
  end

  defp result_of(findings, result) do
    %{findings: findings, requests: [result["request"]["sha256"]], answers: [result["answers"]]}
  end

  # ------------------------------------------------------------- guards ---

  defp guard_item(text) do
    if byte_size(to_string(text)) > @max_item_bytes do
      {:error,
       %{
         finding:
           Finding.new("jev-item-too-large", nil, %{
             "layer" => "jev",
             "severity" => "advisory",
             "scope" => "draft",
             "message" => "A Jev request item is over #{@max_item_bytes} bytes and was not sent."
           })
       }}
    else
      :ok
    end
  end

  defp guard_items(id, texts) do
    oversized = Enum.filter(texts, &(byte_size(to_string(&1)) > @max_item_bytes))

    if oversized == [] do
      :ok
    else
      {:error,
       %{
         finding:
           Finding.new("jev-item-too-large", id, %{
             "layer" => "jev",
             "severity" => "advisory",
             "scope" => "draft",
             "message" =>
               "#{length(oversized)} Jev request item(s) for `#{id}` are over #{@max_item_bytes} bytes and were not sent."
           })
       }}
    end
  end

  defp guard_request(id, body) do
    if byte_size(body) > @max_request_bytes do
      {:error,
       %{
         finding:
           Finding.new("jev-request-too-large", id, %{
             "layer" => "jev",
             "severity" => "advisory",
             "scope" => "draft",
             "message" =>
               "The Jev request `#{id}` is #{byte_size(body)} bytes, over the #{@max_request_bytes}-byte limit, and was not sent."
           })
       }}
    else
      :ok
    end
  end

  # -------------------------------------------------------------- jobs ---

  defp run_jobs([], _deadline, _deadline_ms), do: {:ok, []}

  defp run_jobs(jobs, deadline, deadline_ms) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    results =
      jobs
      |> Task.async_stream(fn job -> job.() end,
        max_concurrency: @max_concurrency,
        timeout: remaining,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    cond do
      Enum.any?(results, &match?({:exit, :timeout}, &1)) ->
        {:error, "the Jev layer's #{deadline_ms} ms deadline elapsed"}

      error = Enum.find_value(results, fn {:ok, r} -> if match?({:error, _}, r), do: r end) ->
        error

      true ->
        {:ok, Enum.map(results, fn {:ok, r} -> r end)}
    end
  end

  defp answer_map(requests, answers) do
    requests
    |> Enum.zip(answers)
    |> Map.new()
  end

  # ------------------------------------------------------------- setup ---

  defp jev_opts(ctx) do
    [
      security: Map.get(ctx[:env] || %{}, "KOGEN_JEV_SECURITY"),
      transport: executable_transport(Map.get(ctx[:env] || %{}, "KOGEN_JEV_TRANSPORT"))
    ]
  end

  defp executable_transport(nil), do: nil
  defp executable_transport(""), do: nil
  defp executable_transport(executable) when is_function(executable, 1), do: executable

  defp executable_transport(executable) do
    fn %{url: url, headers: headers, body: body, timeout: timeout} ->
      payload =
        Jason.encode!(%{
          "url" => url,
          "timeout_ms" => timeout,
          "headers" => Map.new(headers),
          "body" => body
        })

      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide
        ])

      Port.command(port, [Integer.to_string(byte_size(payload)), "\n", payload])
      collect_executable(port, [], System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp collect_executable(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_executable(port, [acc, data], deadline)

      {^port, {:exit_status, 0}} ->
        decode_executable(IO.iodata_to_binary(acc))

      {^port, {:exit_status, status}} ->
        {:error, {:transport_exit, status}}
    after
      remaining ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp decode_executable(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => "timeout"}} -> {:error, :timeout}
      {:ok, %{"error" => reason}} -> {:error, reason}
      {:ok, %{"status" => status, "body" => body}} -> {:ok, %{status: status, body: body}}
      _ -> {:error, :invalid_transport_output}
    end
  end

  defp unavailable(findings, reason) do
    finding =
      Finding.new("jev-unavailable", nil, %{
        "layer" => "jev",
        "severity" => "advisory",
        "scope" => "environment",
        "message" => "The Jev layer is unavailable: #{reason}"
      })

    %{
      "status" => "unavailable",
      "reason" => reason,
      "findings" => [finding],
      "routed_findings" => findings,
      "requests" => [],
      "answers" => [],
      "routes" => []
    }
  end
end
