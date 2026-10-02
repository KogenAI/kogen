defmodule Kogen.Harness.PlanSanitizer do
  @moduledoc false

  @path_pattern ~r/\b(?:lib|test|priv|docs|config|assets|src|app)\/[A-Za-z0-9_.\/*-]+/
  @root_file_pattern ~r/\b[A-Za-z0-9_.-]+\.(?:ex|exs|md|yaml|yml|json|toml|txt|lock)\b/
  @dependency_pattern ~r/\b(?:add|install|introduce|pull in|include)\b.*\b(?:dependency|dependencies|package|library|hex|npm|service)\b/i

  @spec clean(String.t(), String.t(), map()) :: String.t()
  def clean(plan_text, intent_text, domains) do
    declared_domains = intent_domains(intent_text)
    allowed_paths = allowed_paths(domains, declared_domains)

    plan_text
    |> String.split("\n", trim: false)
    |> Enum.reject(fn line ->
      dependency_line?(line, intent_text) or out_of_scope_line?(line, intent_text, allowed_paths)
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp intent_domains(intent_text) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---/s, intent_text, capture: :all_but_first) do
      [frontmatter] -> parse_domain_lines(String.split(frontmatter, "\n"))
      _missing -> []
    end
  end

  defp parse_domain_lines(lines) do
    case_result =
      case Enum.find(lines, &String.starts_with?(String.trim(&1), "domains:")) do
        nil -> []
        line -> inline_domains(line) ++ list_domains(lines)
      end

    Enum.uniq(case_result)
  end

  defp inline_domains(line) do
    case Regex.run(~r/domains:\s*\[([^\]]*)\]/, line, capture: :all_but_first) do
      [values] ->
        values |> String.split(",") |> Enum.map(&clean_domain/1) |> Enum.reject(&(&1 == ""))

      _none ->
        []
    end
  end

  defp list_domains(lines) do
    lines
    |> Enum.drop_while(&(not String.starts_with?(String.trim(&1), "domains:")))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(String.trim(&1), "-"))
    |> Enum.map(&clean_domain/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp clean_domain(value) do
    value
    |> String.trim()
    |> String.trim_leading("-")
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim_trailing(",")
    |> String.trim("'")
    |> String.trim("\"")
    |> String.trim()
  end

  defp allowed_paths(domains, declared_domains) do
    domains
    |> Enum.filter(fn {name, _paths} -> name in declared_domains end)
    |> Enum.flat_map(fn {_name, paths} -> paths end)
  end

  defp dependency_line?(line, intent_text) do
    Regex.match?(@dependency_pattern, line) and
      not String.contains?(String.downcase(intent_text), String.downcase(String.trim(line)))
  end

  defp out_of_scope_line?(line, intent_text, allowed_paths) do
    line
    |> paths_in_line()
    |> Enum.any?(fn path -> not path_allowed?(path, intent_text, allowed_paths) end)
  end

  defp paths_in_line(line) do
    directory_paths = @path_pattern |> Regex.scan(line) |> List.flatten()

    root_files =
      @root_file_pattern
      |> Regex.scan(line)
      |> List.flatten()
      |> Enum.reject(fn file ->
        Enum.any?(directory_paths, &String.ends_with?(&1, "/" <> file))
      end)

    (directory_paths ++ root_files)
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.uniq()
  end

  defp path_allowed?(path, intent_text, allowed_paths) do
    String.contains?(intent_text, path) or
      Enum.any?(allowed_paths, fn prefix ->
        path == prefix or String.starts_with?(path, prefix <> "/")
      end)
  end
end
