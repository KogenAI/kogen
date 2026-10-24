ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")

defmodule ApprovalRecoveryExercise do
  import ExUnit.Assertions
  alias Kogen.{Config, Intent, SourceProvenance, WorkingContext}
  alias Kogen.Integration.{Helpers, FakeProvider}

  def put(c, p, bytes) do
    full = Path.join(c.repo, p)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
  end
  def git(c, args) do
    {out, 0} = Helpers.git!(c, args)
    String.trim(out)
  end
  def sha(c, slug), do: Intent.hash(c.repo, Intent.baseline(c.repo, slug, Config.load!(c.repo)))
  def marker(c, slug), do: Intent.approval_path(c.repo, slug)
  def state(c), do: {git(c, ["rev-parse", "HEAD"]), File.read!(Path.join(c.repo, ".git/index"))}
  def count(c), do: length(FakeProvider.provider_requests(c.server))
  def call(name, args), do: {:function, name, args}
  def invoke(c, args, exit) do
    {out, code} = Helpers.run_kogen(c, args)
    if code != exit, do: IO.inspect(FakeProvider.tool_outputs(c.server), label: "tool feedback", limit: :infinity)
    assert code == exit, "expected #{exit}, got #{code}: #{out}"
    out
  end
  def files(slug, helper, title) do
    dir = Intent.dir(slug)
    %{
      "#{dir}/intent.md" => """
      # #{title}

      Slug: #{slug}
      Model: not applicable — stateless fixture
      Acceptance:
      - #{dir}/acceptance.feature
      - #{helper}

      Write verified edit followed by a newline to app.txt when building this fixture.

      ## Decisions
      - Keep native authority checks. (source: request)

      ## Source comparison
      - addressed: requested verified edit newline in app.txt; source request; contract outcome and acceptance.

      ## Tests
      - fixture availability: real Cucumber (scenario)

      ## Stages
      ```json
      {"version":1,"stages":[{"id":"prepare","title":"Prepare fixture","goal":"Keep the seeded app available","checks":["test -f app.txt"]},{"id":"deliver","title":"Deliver fixture","goal":"Write the approved text","checks":["test -f app.txt"]}]}
      ```

      ## Feasibility
      - none
      """,
      "#{dir}/acceptance.feature" => "Feature: Approval recovery fixture\n  Scenario: Fixture is available\n    Then the approval recovery fixture passes\n",
      helper => "const {Then}=require('@cucumber/cucumber');\nThen('the approval recovery fixture passes',()=>{});\n"
    }
  end
  def shape(c, slug, pkg, request_text) do
    request = Path.join(c.root, "request.md")
    File.write!(request, request_text)
    FakeProvider.append(c.server, [
      call("read_file", %{"path" => "app.txt"}),
      call("read_file", %{"path" => ".kogen/project.yaml"}),
      call("submit", %{"files" => Enum.map(pkg, fn {p,b} -> %{"path" => p, "content" => b} end)})
    ])
    invoke(c, ["intent", "shape", slug, request], 0)
  end
  def all_files(root) do
    case File.ls(root) do
      {:ok, names} -> Enum.flat_map(names, fn name ->
        p = Path.join(root, name)
        case File.lstat!(p).type do
          :directory -> all_files(p)
          :regular -> [p]
          _ -> []
        end
      end)
      {:error, :enoent} -> []
    end
  end
  def retained(c, slug, old_approval, old_source) do
    excluded = [marker(c, slug), SourceProvenance.path(c.repo, slug)]
    paths = all_files(Path.join(c.repo, ".kogen/local")) -- excluded
    found = fn bytes -> bytes == nil or Enum.any?(paths, &(File.read!(&1) == bytes)) end
    found.(old_approval) and found.(old_source)
  end
  def source_bytes(c, slug) do
    case File.read(SourceProvenance.path(c.repo, slug)) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> nil
    end
  end
  def source_ok(c, slug, original) do
    case source_bytes(c, slug) do
      nil -> original == nil
      bytes -> original == nil or Map.take(JSON.decode!(bytes), ["request", "rounds", "origin"]) == Map.take(JSON.decode!(original), ["request", "rounds", "origin"])
    end
  end
  def current_bound(c, slug) do
    approval = JSON.decode!(File.read!(marker(c, slug)))
    ref = approval["source_provenance"]
    doc = JSON.decode!(File.read!(SourceProvenance.path(c.repo, slug)))
    approval["sha256"] == sha(c, slug) and ref["contract_sha256"] == sha(c, slug) and
      doc["contract_sha256"] == sha(c, slug) and ref["sha256"] == WorkingContext.hash(File.read!(ref["path"]))
  end
  def park(c, slug, helper) do
    archive = Path.join(c.root, "parked-package-#{System.unique_integer([:positive])}")
    File.mkdir_p!(archive)
    File.rename!(Path.join(c.repo, Intent.dir(slug)), Path.join(archive, "intent"))
    File.rename!(Path.join(c.repo, helper), Path.join(archive, "helper.js"))
    archive
  end
  def setup(c, slug, mode) do
    helper = if String.contains?(mode, "shared"), do: "features/steps/workspace-project-access.js", else: "features/steps/approval_fixture.js"
    pkg = files(slug, helper, "Preserve the authority fixture")
    legacy = mode == "legacy-refine"
    if legacy do
      for {p,b} <- pkg, do: put(c,p,b)
    else
      shape(c, slug, pkg, "Original source for #{slug}: write verified edit newline to app.txt.\n")
    end
    invoke(c, ["intent", "approve", slug, sha(c, slug)], 0)
    old_approval = File.read!(marker(c, slug))
    old_source = source_bytes(c, slug)
    cond do
      String.contains?(mode, "parked") or mode == "missing-history" ->
        park(c, slug, helper)
        shape(c, slug, files(slug, helper, "Review the fresh authority fixture"), "Fresh same-slug request for #{slug}: write verified edit newline to app.txt.\n")
      String.contains?(mode, "shared") ->
        consumer = files("shared-consumer", helper, "Preserve shared acceptance") |> Map.delete(helper)
        for {p,b} <- consumer, do: put(c,p,b)
        git(c, ["add", "-A"])
        git(c, ["commit", "-qm", "Land the shared acceptance fixture"])
        put(c, helper, pkg[helper] <> "\n// Legitimate separately landed shared helper change.\n")
        git(c, ["add", helper])
        git(c, ["commit", "-qm", "Change the shared acceptance helper"])
        assert source_bytes(c, slug) == old_source
      legacy ->
        p = Intent.intent_md(slug)
        put(c,p,pkg[p] <> "\nClarify the ready unapproved draft.\n")
      true -> :ok
    end
    {old_approval, old_source}
  end
  def build(c, slug, observations) do
    before = git(c, ["rev-parse", "HEAD"])
    reviews = length(FakeProvider.review_requests(c.server))
    FakeProvider.append(c.server, [
      call("write_file", %{"path" => "app.txt", "content" => "verified edit\n"}),
      call("finish", %{"summary" => "Prepare"}),
      call("finish", %{"summary" => "Deliver"}),
      call("finish", %{"summary" => "Ready"}),
      call("submit_review", %{"verdict" => "approve", "findings" => []})
    ])
    out = invoke(c, ["intent", "build", slug], 0)
    [result] = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/result.json"))
    progress = JSON.decode!(File.read!(result))["stage_progress"]
    Map.merge(observations, %{
      "staged Build retained" => progress["total"] == 2 and progress["completed"] == ["prepare", "deliver"],
      "fresh Build landed" => out =~ "landed #{slug}" and git(c,["rev-parse", "HEAD"]) != before and File.read!(Path.join(c.repo,"app.txt")) == "verified edit\n",
      "independent review ran" => length(FakeProvider.review_requests(c.server)) > reviews,
      "new approval consumed" => not File.exists?(marker(c,slug))
    })
  end
  def refine(c, slug, old_approval, old_source, control) do
    before = state(c)
    original_source = source_bytes(c, slug)
    p = Intent.intent_md(slug)
    body = File.read!(Path.join(c.repo,p)) <> "\nA supported narrow correction.\n"
    correction = Path.join(c.root,"correction.md")
    File.write!(correction,"Clarify only the owned Intent prose; retain executable behavior.\n")
    FakeProvider.append(c.server,[call("submit_refinement",%{"files" => [%{"path" => p,"content" => body}]})])
    invoke(c,["intent","refine",slug,sha(c,slug),correction],0)
    # Damage real retained marker files after supported normal Refine. Final
    # approval and Build still run, so the deep history assertion is not masked.
    if control == "control-bad" do
      for f <- all_files(Path.join(c.repo,".kogen/local")), File.read!(f) == old_approval do
        File.write!(f, old_approval <> " ")
      end
    end
    observations = %{
      "refinement succeeded" => true,
      "approval revoked" => not File.exists?(marker(c,slug)),
      "history retained" => retained(c,slug,old_approval,old_source),
      "source originals preserved" => source_ok(c,slug,original_source),
      "correction retained" => File.read!(Path.join(c.repo,p)) == body,
      "HEAD and index preserved" => state(c) == before
    }
    out = invoke(c,["intent","build",slug],5)
    observations = Map.put(observations,"fresh approval required",out =~ "intent/not_approved")
    if control do
      invoke(c,["intent","approve",slug,sha(c,slug)],0)
      observations = Map.merge(observations,%{"exact current approval" => true,"current source bound" => current_bound(c,slug)})
      build(c,slug,observations)
    else
      observations
    end
  end
  def approve(c, slug, old_approval, old_source) do
    before = state(c)
    original_source = source_bytes(c, slug)
    n = count(c)
    mismatch = invoke(c,["intent","build",slug],1)
    wrong = invoke(c,["intent","approve",slug,JSON.decode!(old_approval)["sha256"]],1)
    current = sha(c,slug)
    stable = state(c) == before and File.read!(marker(c,slug)) == old_approval
    card = invoke(c,["intent","approve",slug],5)
    observations = %{
      "stale Build refused without inference" => mismatch =~ "intent/changed_since_approval" and count(c) == n,
      "wrong approval hash preserved state" => wrong =~ "intent/hash_mismatch" and wrong =~ current and stable,
      "current card full hash" => card =~ "SHA-256: #{current}" and card =~ "kogen intent approve #{slug} #{current}",
      "complete staged card" => Enum.all?(["Staged plan", "1. Prepare fixture (prepare): Keep the seeded app available", "2. Deliver fixture (deliver): Write the approved text", "test -f app.txt"], &String.contains?(card, &1)),
      "stale authority visible" => card =~ "Stale approval" and card =~ JSON.decode!(old_approval)["sha256"],
      "card did not replace approval" => File.read!(marker(c,slug)) == old_approval and state(c) == before
    }
    out = invoke(c,["intent","approve",slug,current],0)
    observations = Map.merge(observations,%{
      "exact current approval" => out =~ "approved #{slug}" and JSON.decode!(File.read!(marker(c,slug)))["sha256"] == current,
      "history retained" => retained(c,slug,old_approval,old_source),
      "current source bound" => current_bound(c,slug),
      "source originals preserved" => source_ok(c,slug,original_source)
    })
    build(c,slug,observations)
  end
  def unsafe(c, slug, mode, old_approval, old_source) do
    p = SourceProvenance.path(c.repo,slug)
    if mode == "missing-history" do
      for f <- all_files(Path.dirname(p)), File.read!(f) == old_source, do: File.rm!(f)
    else
      if mode == "missing-current", do: File.rm!(p), else: File.write!(p,File.read!(p) <> " ")
    end
    before = state(c)
    source = File.read(p)
    n = count(c)
    results = for args <- [["intent","approve",slug],["intent","approve",slug,sha(c,slug)]] do
      Helpers.run_kogen(c,args)
    end
    %{
      "custody refused" => Enum.all?(results,fn {o,e} -> e == 1 and o =~ "source_provenance_changed" end),
      "actual cause and next action" => Enum.all?(results,fn {o,_} -> o =~ "provenance" and o =~ slug and String.match?(o,~r/restore/i) and not (o =~ "obtain fresh exact approval") end),
      "approval and source unchanged" => File.read!(marker(c,slug)) == old_approval and File.read(p) == source,
      "HEAD and index preserved" => state(c) == before,
      "no provider inference" => count(c) == n
    }
  end
  def invalid(c, slug, old_approval) do
    p = Intent.intent_md(slug)
    put(c, p, String.replace(File.read!(Path.join(c.repo,p)), "Model: not applicable — stateless fixture", "Model: invalid"))
    before = state(c)
    source = source_bytes(c,slug)
    package = File.read!(Path.join(c.repo,p))
    n = count(c)
    {out, code} = Helpers.run_kogen(c,["intent","approve",slug])
    %{"invalid package cause" => code == 1 and out =~ "intent/lint" and out =~ "Model:" and not (out =~ "source_provenance_changed"),
      "approval and source unchanged" => File.read!(marker(c,slug)) == old_approval and source_bytes(c,slug) == source,
      "HEAD and index preserved" => state(c) == before,
      "package unchanged" => File.read!(Path.join(c.repo,p)) == package,
      "no provider inference" => count(c) == n}
  end
  def run(mode, slug) do
    suite = Helpers.setup_suite!()
    try do
      c = Helpers.project!(suite, [], staged_intent: false)
      try do
        git(c, ["add", "-A"])
        git(c, ["commit", "-qm", "Commit the seed fixture"])
        {old_approval, old_source} = setup(c,slug,mode)
        cond do
          mode == "invalid-shared" -> invalid(c,slug,old_approval)
          String.starts_with?(mode,"control-") -> refine(c,slug,old_approval,old_source,mode)
          String.contains?(mode,"refine") -> refine(c,slug,old_approval,old_source,nil)
          mode in ["missing-current","tampered-current","missing-history"] -> unsafe(c,slug,mode,old_approval,old_source)
          true -> approve(c,slug,old_approval,old_source)
        end
      after
        Helpers.cleanup_case(c)
      end
    after
      Helpers.cleanup_suite(suite)
    end
  end
end

result = ApprovalRecoveryExercise.run(System.fetch_env!("ACR_MODE"),System.fetch_env!("ACR_SLUG"))
File.write!(System.fetch_env!("ACR_RECEIPT"),JSON.encode!(result))
