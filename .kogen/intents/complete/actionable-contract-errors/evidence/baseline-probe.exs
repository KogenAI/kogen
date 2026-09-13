alias Kogen.Build.Contract

contract = %{scenarios: [%{"id" => "one"}, %{"id" => "two"}], risks: []}
ref = %{"path" => "README.md", "locator" => "Kogen"}
entries = for id <- ["one", "two"], do: %{"id" => id, "status" => "ready", "claim" => "Implemented", "implementation" => [ref], "evidence" => [ref]}
handoff = %{"attempt_token" => "probe", "scenarios" => entries, "risks" => [], "findings" => []}
cases = [
  {"valid", handoff},
  {"directory", put_in(handoff, ["scenarios", Access.at(1), "evidence", Access.at(0), "path"], "lib")},
  {"missing", Map.put(handoff, "scenarios", [hd(entries)])},
  {"duplicate", Map.put(handoff, "scenarios", entries ++ [hd(entries)])},
  {"unexpected", put_in(handoff, ["scenarios", Access.at(1), "id"], "unknown")}
]
Enum.each(cases, fn {label, value} ->
  result = Contract.handoff(Jason.encode!(value), contract, "probe", [])
  IO.puts("#{label}: #{inspect(result, limit: :infinity)}")
end)
verdict = %{"candidate_id" => "candidate", "attempt_token" => "probe", "verdict" => "accept", "scenarios" => Enum.map(entries, fn entry -> %{"id" => entry["id"], "status" => "satisfied", "reason" => "Inspected", "evidence" => [ref]} end), "dispositions" => [], "findings" => []}
binding = %{candidate_id: "candidate", attempt_token: "probe"}
IO.puts("valid verdict: #{inspect(Contract.verdict(verdict, contract, binding, []), limit: :infinity)}")
invalid = put_in(verdict, ["scenarios", Access.at(1), "evidence", Access.at(0), "path"], "lib")
IO.puts("directory verdict: #{inspect(Contract.verdict(invalid, contract, binding, []))}")
