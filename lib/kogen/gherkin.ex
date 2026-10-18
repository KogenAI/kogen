defmodule Kogen.Gherkin do
  @moduledoc """
  Reads a `.feature` file (English keywords) far enough to know its scenarios: Kogen counts the
  expected scenarios itself (VER-4) and checks the Intent's acceptance rules (SHP-5).

  `parse/1` returns `{:ok, [scenario]}` where each scenario (one per Scenario, one per Examples
  row of an Outline) is `%{name, line, tags, steps: [%{keyword, text, line}]}` with the line
  Cucumber reports for it. Outline pickles also carry their original name, outline line and number
  of Examples rows, or parsing returns `{:error, line, message}`.
  """

  @step_keywords ["Given ", "When ", "Then ", "And ", "But ", "* "]
  @scenario_keywords ["Scenario Outline:", "Scenario Template:", "Scenario:", "Example:"]
  @examples_keywords ["Examples:", "Scenarios:"]

  def parse(text) do
    lines = text |> String.split("\n") |> Enum.with_index(1)

    try do
      st =
        Enum.reduce(
          lines,
          %{
            mode: :start,
            tags: [],
            feature_tags: [],
            rule_tags: [],
            bg: [],
            rule_bg: [],
            cur: nil,
            out: [],
            doc: nil,
            in_rule: false
          },
          &line/2
        )

      if st.doc, do: throw({:gherkin, elem(st.doc, 1), "the doc string is not closed"})
      if st.mode == :start, do: throw({:gherkin, 1, "the file has no Feature:"})
      {:ok, st |> close() |> Map.fetch!(:out) |> Enum.reverse() |> Enum.flat_map(&pickles/1)}
    catch
      {:gherkin, n, msg} -> {:error, n, msg}
    end
  end

  # Inside a doc string everything up to the closing fence is content.
  defp line({raw, _n}, %{doc: {fence, _start}} = st) do
    if String.trim(raw) == fence, do: %{st | doc: nil}, else: st
  end

  defp line({raw, n}, st) do
    t = String.trim(raw)

    cond do
      t == "" or String.starts_with?(t, "#") ->
        st

      String.starts_with?(t, "@") ->
        %{st | tags: st.tags ++ tags(t, n)}

      st.mode == :start ->
        feature(t, n, st)

      String.starts_with?(t, "Background:") ->
        section(%{close(st) | mode: :background, tags: []}, n, :background)

      String.starts_with?(t, "Rule:") ->
        %{close(st) | mode: :rule, rule_tags: st.tags, tags: [], in_rule: true, rule_bg: []}

      starts?(t, @scenario_keywords) ->
        scenario(t, n, close(st))

      starts?(t, @examples_keywords) ->
        examples(n, st)

      starts?(t, @step_keywords) ->
        step(t, n, st)

      String.starts_with?(t, "|") ->
        row(t, n, st)

      t in [~s("""), "```"] or String.starts_with?(t, [~s("""), "```"]) ->
        doc(t, n, st)

      st.mode in [:feature, :rule, :background_desc, :scenario_desc, :examples_desc] ->
        st

      true ->
        throw({:gherkin, n, "unexpected text: #{t}"})
    end
  end

  defp starts?(t, prefixes), do: Enum.any?(prefixes, &String.starts_with?(t, &1))

  defp tags(t, n) do
    t
    |> String.split(~r/\s+#/, parts: 2)
    |> hd()
    |> String.split()
    |> Enum.map(fn
      "@" <> _ = tag -> tag
      other -> throw({:gherkin, n, "a tag must start with @: #{other}"})
    end)
  end

  defp feature("Feature:" <> _, _n, st),
    do: %{st | mode: :feature, feature_tags: st.tags, tags: []}

  defp feature(t, n, _st), do: throw({:gherkin, n, "expected Feature:, got: #{t}"})

  defp section(st, _n, :background), do: %{st | mode: :background_desc, cur: {:background, []}}

  defp scenario(t, n, st) do
    [kw, name] = String.split(t, ":", parts: 2)
    outline = kw in ["Scenario Outline", "Scenario Template"]
    rule_tags = if st.in_rule, do: st.rule_tags, else: []

    %{
      st
      | mode: :scenario_desc,
        tags: [],
        cur: %{
          name: String.trim(name),
          line: n,
          outline: outline,
          tags: st.feature_tags ++ rule_tags ++ st.tags,
          steps: [],
          examples: []
        }
    }
  end

  defp examples(n, %{cur: %{outline: true} = cur} = st) do
    ex = %{line: n, tags: st.tags, header: nil, rows: []}
    %{st | mode: :examples_desc, tags: [], cur: %{cur | examples: cur.examples ++ [ex]}}
  end

  defp examples(n, _st), do: throw({:gherkin, n, "Examples: belongs to a Scenario Outline"})

  defp step(t, n, %{cur: {:background, steps}} = st),
    do: %{st | mode: :background, cur: {:background, steps ++ [parse_step(t, n)]}}

  defp step(t, n, %{cur: %{examples: []} = cur} = st),
    do: %{st | mode: :scenario, cur: %{cur | steps: cur.steps ++ [parse_step(t, n)]}}

  defp step(t, n, _st),
    do: throw({:gherkin, n, "a step must belong to a Scenario or Background: #{t}"})

  defp parse_step(t, n) do
    [kw | _] = Enum.filter(@step_keywords, &String.starts_with?(t, &1))
    %{keyword: kw, text: String.trim(String.replace_prefix(t, kw, "")), line: n}
  end

  # A table row: an argument of the last step, or an Examples row.
  defp row(t, n, %{cur: %{examples: [_ | _] = exs} = cur} = st) do
    cells = cells(t, n)
    {ex, earlier} = List.pop_at(exs, -1)

    ex =
      if ex.header,
        do: %{ex | rows: ex.rows ++ [%{line: n, cells: cells}]},
        else: %{ex | header: cells}

    if ex.header && length(cells) != length(ex.header),
      do:
        throw(
          {:gherkin, n, "this row has #{length(cells)} cells, the header #{length(ex.header)}"}
        )

    %{st | mode: :examples, cur: %{cur | examples: earlier ++ [ex]}}
  end

  defp row(t, n, %{mode: mode} = st) when mode in [:scenario, :background] do
    cells(t, n)
    st
  end

  defp row(_t, n, _st), do: throw({:gherkin, n, "a table must follow a step or Examples:"})

  defp cells(t, n) do
    if not String.ends_with?(t, "|"), do: throw({:gherkin, n, "a table row must end with |"})
    t |> String.slice(1..-2//1) |> String.split(~r/(?<!\\)\|/) |> Enum.map(&String.trim/1)
  end

  defp doc(t, n, %{mode: mode} = st) when mode in [:scenario, :background] do
    fence = if String.starts_with?(t, "```"), do: "```", else: ~s(""")
    %{st | doc: {fence, n}}
  end

  defp doc(_t, n, _st), do: throw({:gherkin, n, "a doc string must follow a step"})

  defp close(%{cur: nil} = st), do: st
  # A Rule's Background adds to the Feature's, for that Rule only.
  defp close(%{cur: {:background, steps}, in_rule: true} = st),
    do: %{st | cur: nil, rule_bg: steps}

  defp close(%{cur: {:background, steps}} = st), do: %{st | cur: nil, bg: steps}

  defp close(%{cur: cur} = st) do
    if cur.outline and Enum.all?(cur.examples, &(&1.rows == [])),
      do: throw({:gherkin, cur.line, "Scenario Outline #{cur.name} has no Examples rows"})

    %{st | cur: nil, out: [Map.put(cur, :background, st.bg ++ st.rule_bg) | st.out]}
  end

  defp pickles(%{outline: false} = s),
    do: [%{name: s.name, line: s.line, tags: s.tags, steps: s.background ++ s.steps}]

  defp pickles(%{outline: true} = s) do
    for ex <- s.examples, ex.header != nil, row <- ex.rows do
      values = Enum.zip(ex.header, row.cells)

      subst = fn text ->
        Enum.reduce(values, text, fn {k, v}, acc -> String.replace(acc, "<#{k}>", v) end)
      end

      steps = Enum.map(s.steps, &%{&1 | text: subst.(&1.text)})

      %{
        name: subst.(s.name),
        line: row.line,
        tags: s.tags ++ ex.tags,
        outline_name: s.name,
        outline_line: s.line,
        outline_examples: Enum.reduce(s.examples, 0, &(length(&1.rows) + &2)),
        steps: s.background ++ steps
      }
    end
  end
end
