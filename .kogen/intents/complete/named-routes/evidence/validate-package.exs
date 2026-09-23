dir = ".kogen/intents/drafts/named-routes"
{:ok, intent} = Kogen.Intent.read("named-routes", ".kogen/intents/drafts")
IO.inspect(intent.title, label: "intent")
IO.inspect(Kogen.Intent.read_draft("named-routes") |> elem(0), label: "read_draft")
IO.inspect(Kogen.Build.Contract.load(dir) |> elem(0), label: "contract")
{:ok, scenarios} = YamlElixir.read_from_file(Path.join(dir, "scenarios.yaml"))
{:ok, catalog} = Kogen.Build.VerificationPlan.load()
res = Kogen.Build.VerificationPlan.build(scenarios, intent.may_change_guarded_paths, catalog)
IO.inspect(res |> elem(0), label: "plan")
case res do
  {:ok, plan} -> IO.inspect(Map.take(plan, [:offline, :targets, :rehearsals]) , label: "plan detail", limit: :infinity)
  other -> IO.inspect(other)
end
{:ok, risks} = YamlElixir.read_from_file(Path.join(dir, "risks.yaml"))
IO.inspect(length(risks), label: "risks")
