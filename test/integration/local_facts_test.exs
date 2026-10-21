defmodule Kogen.LocalFactsTest do
  use ExUnit.Case, async: false
  alias Kogen.{LocalFacts, Lock, Run}

  setup do
    root = Kogen.tmp_path("local-facts-test")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q", root])
    File.mkdir_p!(Path.join(root, ".kogen"))
    File.write!(Path.join(root, ".kogen/project.yaml"), Kogen.Config.template())
    lock = Path.join(root, ".kogen/local/build.lock")
    :ok = Lock.acquire(lock)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, lock: lock}
  end

  test "start publishes coherent custody and repeated replacements never tear", %{
    root: root,
    lock: lock
  } do
    first = Run.start(root)
    LocalFacts.start(root, "fixture", first)
    path = Path.join(root, ".kogen/local/context.json")

    reader =
      Task.async(fn ->
        for _ <- 1..300 do
          doc = File.read!(path) |> JSON.decode!()
          assert doc["active"]["run_id"] == doc["last_built"]["run_id"]
          assert doc["active"]["phase"] == "startup"
          assert doc["active"]["verification_pass"] == nil
        end
      end)

    for _ <- 1..20, do: LocalFacts.start(root, "fixture", Run.start(root))
    Task.await(reader)
    assert File.ls!(lock) == [JSON.decode!(File.read!(path))["owner"]["token"]]
    Lock.release(lock)
  end

  test "damaged catalog cannot abort custody publication; inherited evidence keeps original locations",
       %{root: root} do
    File.write!(Path.join(root, ".kogen/local/catalog.json"), "{broken")
    original = Run.start(root)
    LocalFacts.start(root, "fixture", original)
    resumed = Run.start(root)
    LocalFacts.start(root, "fixture", resumed, original.id, original.id)
    pass = %{n: 3, green: true, tree: "tree", failing: [], not_run: []}

    review = %{
      n: 1,
      verdict: "changes",
      findings: [%{"path" => "app.txt", "severity" => "blocking", "message" => "fix"}]
    }

    b = %{
      root: root,
      run: resumed,
      pass: 3,
      last_pass: pass,
      last_review: review,
      blocker: nil,
      continuation: %{stage: :review_verify}
    }

    LocalFacts.inherit(b, original)
    LocalFacts.update(b, "reviewing", "review_blocked")
    doc = File.read!(Path.join(root, ".kogen/local/facts/#{resumed.id}.json")) |> JSON.decode!()
    assert hd(doc["verification"])["path"] == original.log
    assert hd(doc["reviews"])["path"] == original.log
    assert hd(doc["blockers"])["paths"] == ["app.txt"]
    assert doc["resumed_from"] == original.id
    assert doc["root_run"] == original.id
  end
end
