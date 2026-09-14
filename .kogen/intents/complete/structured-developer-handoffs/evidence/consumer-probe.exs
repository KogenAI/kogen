[repo, base] = System.argv()
Code.compile_file(Path.join(repo, "lib/kogen/build/contract.ex"))
File.cd!(Path.join(base, "native-fixture"))
contract = %{scenarios: [%{"id" => "s1"}, %{"id" => "s2"}], risks: [%{"id" => "r1", "scenario_ids" => ["s1", "s2"]}]}
findings = [%{"id" => "f1", "scenario_ids" => ["s1"]}]
original = File.read!(Path.join(base, "fresh.message.json")) |> Jason.decode!()
refs = [%{"path" => "source.txt", "locator" => "line 1"}]
valid = Map.update!(original, "scenarios", &Enum.map(&1, fn s -> Map.put(s, "implementation", refs) end))
cases = [
 {"native-empty-references", original, false},
 {"valid-control", valid, true},
 {"stale-token", Map.put(valid, "attempt_token", "attempt-zero"), false},
 {"duplicate-scenario", Map.update!(valid,"scenarios",fn [a,_b] -> [a,a] end), false},
 {"missing-file", put_in(valid,["scenarios",Access.at(0),"evidence"], [%{"path"=>"absent.txt","locator"=>"line 1"}]), false},
 {"incomplete", put_in(valid,["scenarios",Access.at(0),"status"], "incomplete"), false},
 {"blocked", put_in(valid,["findings",Access.at(0),"status"], "blocked"), false},
 {"wrong-links",put_in(valid,["risks",Access.at(0),"scenario_ids"],["s2","s1"]),false}
]
results = Enum.map(cases,fn {label,value,expected} ->
 result=Kogen.Build.Contract.handoff(Jason.encode!(value),contract,"attempt-one",findings)
 actual=match?({:ok,_},result)
 if actual != expected, do: raise("unexpected result #{label}")
 %{case: label, accepted: actual, result: inspect(result)}
end)
results = results ++ Enum.map([{"missing",""},{"truncated","{\"attempt_token\":"}],fn {label,text} ->
 result=Kogen.Build.Contract.handoff(text,contract,"attempt-one",findings)
 if not match?({:error,_}, result), do: raise("unexpected #{label}")
 %{case: label, accepted: false, result: inspect(result)}
end)
File.write!(Path.join(base,"consumer-results.json"),Jason.encode!(results,pretty: true))
IO.puts("10 current-source consumer controls passed")
