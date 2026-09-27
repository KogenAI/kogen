defmodule Kogen.ShapingAudit.Fixture do
  @moduledoc """
  The git fixture repository for the Shaping audit's deterministic checks
  (`deterministic-checks` in `scenarios.yaml`): a committed `HEAD` with a
  Makefile declaring `check` and `live-x`, a matching catalog, a
  test-reliability ledger, the controller files, `lib/a.ex` and
  `test/a_test.exs`. A second commit edits `lib/a.ex` line 3 and renames the
  `cited_bytes` identifier to `cited_digest`. The working tree then adds an
  untracked `test/stray_test.exs` and an uncommitted Makefile target
  `live-extra`, neither of which the materialization (a clone of the
  committed objects) ever sees. Retained runtime Build records under
  `.kogen/runtime/scenario-tracking/` hold two failed Builds naming the
  `history` fixture Draft's id, for `prior-failures`.
  """

  @history_intent_id "01965000-0000-7000-8000-000000000001"

  @doc "The fixed intent id the `history` Draft and its retained records share."
  def history_intent_id, do: @history_intent_id

  @doc """
  Builds a fresh fixture repository in a unique temp directory and returns
  its root path. `opts`: `:second_commit` (default `true`), `:working_tree`
  (default `true`, the untracked file and uncommitted target),
  `:prior_failures` (default `true`, the two retained records).
  """
  @spec repo!(keyword()) :: Path.t()
  def repo!(opts \\ []) do
    root =
      if Keyword.get(opts, :compiled, false) do
        Code.ensure_loaded!(Kogen.CompiledFixture)
        Kogen.CompiledFixture.create!(File.cwd!(), "shaping-audit")
      else
        Path.join(
          System.tmp_dir!(),
          "kogen-shaping-fixture-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
        )
      end

    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["config", "user.email", "fixture@example.com"])
    git!(root, ["config", "user.name", "Kogen Fixture"])

    write_initial_tree(root)
    if Keyword.get(opts, :catalog_mismatch, false), do: add_catalog_mismatch(root)
    if Keyword.get(opts, :prepare, false), do: add_prepare_driver(root)
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", "Initial fixture commit"])

    if Keyword.get(opts, :second_commit, true) do
      write_second_commit(root)
      git!(root, ["add", "-A"])
      git!(root, ["commit", "-q", "-m", "Rename cited_bytes to cited_digest"])
    end

    if Keyword.get(opts, :working_tree, true), do: write_working_tree_extras(root)
    if Keyword.get(opts, :prior_failures, true), do: write_prior_failures(root)
    if Keyword.get(opts, :oversized_record, false), do: write_oversized_record(root)

    root
  end

  @doc "The repository's very first commit (the pre-rename baseline)."
  @spec first_commit(Path.t()) :: String.t()
  def first_commit(root) do
    git_out(root, ["rev-list", "--max-parents=0", "HEAD"])
    |> String.trim()
    |> String.split("\n")
    |> List.last()
  end

  @doc "The repository's current `HEAD`."
  @spec head(Path.t()) :: String.t()
  def head(root), do: git_out(root, ["rev-parse", "HEAD"]) |> String.trim()

  @doc """
  Copies `test/support/shaping_audit/drafts/<name>` to
  `.kogen/intents/drafts/<slug>` under `root` (or `.kogen/intents/approved/<slug>`
  with `opts[:dir]: "approved"`), substituting the `__FIRST_COMMIT__` and
  `__HEAD__` template tokens with this repository's commit ids. `slug` is
  read from the copied `intent.yaml`. Returns the package's root-relative
  path.
  """
  @spec add_draft!(Path.t(), String.t(), keyword()) :: String.t()
  def add_draft!(root, name, opts \\ []) do
    source = Path.join([__DIR__, "drafts", name])
    tokens = %{"__FIRST_COMMIT__" => first_commit(root), "__HEAD__" => head(root)}

    files = walk(source)
    slug = slug_of(Path.join(source, "intent.yaml"), tokens)
    dir = if Keyword.get(opts, :dir, "drafts") == "approved", do: "approved", else: "drafts"
    package_rel = Path.join([".kogen/intents", dir, slug])

    Enum.each(files, fn relative ->
      contents = File.read!(Path.join(source, relative)) |> substitute(tokens)
      destination = Path.join([root, package_rel, relative])
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, contents)
    end)

    package_rel
  end

  defp slug_of(intent_path, tokens) do
    {:ok, data} =
      intent_path |> File.read!() |> substitute(tokens) |> YamlElixir.read_from_string()

    Map.fetch!(data, "slug")
  end

  defp substitute(text, tokens),
    do:
      Enum.reduce(tokens, text, fn {token, value}, text -> String.replace(text, token, value) end)

  defp walk(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  # -- committed HEAD content ------------------------------------------------

  defp write_initial_tree(root) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, ".codex/hooks"))
    File.mkdir_p!(Path.join(root, "priv/kogen/claude_code"))
    File.mkdir_p!(Path.join(root, ".kogen"))
    File.mkdir_p!(Path.join(root, "scripts/check"))

    File.write!(Path.join(root, "Makefile"), makefile())
    File.write!(Path.join(root, "priv/kogen/verification_targets.yaml"), catalog_json())
    File.write!(Path.join(root, ".codex/hooks.json"), hooks_json())
    File.write!(Path.join(root, ".codex/hooks/check.sh"), "#!/bin/sh\nexit 0\n")

    File.write!(
      Path.join(root, ".codex/hooks/verification_policy.py"),
      "# stub verification policy\n"
    )

    File.write!(Path.join(root, ".codex/hooks/environment.py"), "# stub environment\n")
    File.write!(Path.join(root, ".codex/hooks/stop_runner.py"), "# stub stop runner\n")
    File.write!(Path.join(root, "priv/kogen/claude_code/settings.json"), "{}\n")
    File.write!(Path.join(root, "lib/a.ex"), lib_a_before())
    File.write!(Path.join(root, "lib/b.ex"), "defmodule B do\n  def value, do: 1\nend\n")
    File.write!(Path.join(root, "test/a_test.exs"), a_test())
    File.write!(Path.join(root, "test/live_x_test.exs"), live_x_test())
    File.write!(Path.join(root, "priv/kogen/test-reliability.yaml"), ledger_json())

    File.write!(
      Path.join(root, "priv/kogen/test-reliability-remediation.yaml"),
      remediation_json()
    )

    File.write!(Path.join(root, ".kogen/config.yaml"), config_yaml())
  end

  defp write_second_commit(root) do
    File.write!(Path.join(root, "lib/a.ex"), lib_a_after())
  end

  defp write_working_tree_extras(root) do
    File.write!(
      Path.join(root, "test/stray_test.exs"),
      "defmodule StrayTest do\n  use ExUnit.Case\n  test \"stray\" do\n    assert true\n  end\nend\n"
    )

    File.write!(Path.join(root, "Makefile"), makefile() <> "live-extra:\n\t@true\n")
  end

  defp write_prior_failures(root) do
    for build_id <- ["FIXTUREBUILD000000000001", "FIXTUREBUILD000000000002"] do
      dir = Path.join(root, ".kogen/runtime/scenario-tracking/#{build_id}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "record.json"), record_json())
    end
  end

  defp write_oversized_record(root) do
    dir = Path.join(root, ".kogen/runtime/scenario-tracking/FIXTUREBUILD000000000003")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "record.json"), :binary.copy(" ", 33 * 1024 * 1024))
  end

  defp record_json do
    Jason.encode!(%{
      "schema_version" => 2,
      "intent" => %{"id" => @history_intent_id},
      "status" => "failed",
      "attempts" => [
        %{
          "number" => 0,
          "status" => "failed",
          "failure" => "Candidate changed paths outside Approved guards: lib/b.ex",
          "failure_signatures" => []
        }
      ]
    })
  end

  defp add_catalog_mismatch(root) do
    path = Path.join(root, "priv/kogen/verification_targets.yaml")
    data = Jason.decode!(File.read!(path))

    extra = %{
      "name" => "mismatch-x",
      "cost_class" => "offline",
      "rank" => 20,
      "dependencies" => [],
      "provider_backed" => false,
      "owner" => "test/a_test.exs"
    }

    File.write!(path, Jason.encode!(Map.update!(data, "targets", &(&1 ++ [extra]))))
  end

  defp add_prepare_driver(root) do
    path = Path.join(root, "priv/kogen/verification_targets.yaml")
    data = Jason.decode!(File.read!(path))

    targets =
      Enum.map(data["targets"], fn
        %{"name" => "live-x"} = target ->
          Map.put(target, "prepare", ["python3", "test/support/live_x_driver.py", "--prepare"])

        target ->
          target
      end)

    File.write!(path, Jason.encode!(Map.put(data, "targets", targets)))
    File.mkdir_p!(Path.join(root, "test/support"))
    File.write!(Path.join(root, "test/support/live_x_driver.py"), "print('prepared')\n")
  end

  defp makefile do
    """
    .PHONY: check live-x
    check:
    \t@true
    live-x:
    \t@true
    """
  end

  defp catalog_json do
    Jason.encode!(%{
      "targets" => [
        %{
          "name" => "check",
          "cost_class" => "offline",
          "rank" => 0,
          "dependencies" => [],
          "provider_backed" => false,
          "owner" => "test/a_test.exs"
        },
        %{
          "name" => "live-x",
          "cost_class" => "paid",
          "rank" => 10,
          "dependencies" => ["check"],
          "provider_backed" => true,
          "owner" => "test/live_x_test.exs",
          "rehearsal" => %{
            "id" => "rehearse-live-x",
            "command" => "true",
            "shared_entrypoints" => ["live-x.entrypoint"],
            "correct_fixture" => "live-x-correct",
            "wrong_fixture" => "live-x-wrong",
            "trace_assertions" => ["live-x-trace"]
          }
        }
      ]
    })
  end

  defp ledger_json do
    Jason.encode!(%{
      "declaration_count" => 1,
      "declarations" => [
        %{
          "id" => "test-a-test-exs:t001",
          "file" => "test/a_test.exs",
          "declaration" => "a works",
          "disposition" => "keep"
        }
      ]
    })
  end

  defp remediation_json do
    Jason.encode!(%{
      "schema_version" => 1,
      "intent_id" => "fixture",
      "declaration_count" => 1,
      "resolved" => [
        %{
          "id" => "test-a-test-exs:t001",
          "disposition" => "keep",
          "scenario" => "a-helper-computes",
          "implementation" => "scripts/check/generate_test_reliability.py",
          "wrong_control_locator" =>
            "test-a-test-exs:t001: rejects the passing-wrong authority variant",
          "resolution" => "source-specific preservation challenge"
        }
      ]
    }) <> "\n"
  end

  defp config_yaml do
    """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping: {model: gpt-5.6-sol, effort: low}
        developer: {model: gpt-5.6-sol, effort: low}
        reviewer: {model: gpt-5.6-terra, effort: medium}
        helpers:
          scout: {model: gpt-5.6-luna, effort: low}
          worker: {model: gpt-5.6-luna, effort: medium}
          expert: {model: gpt-5.6-sol, effort: medium}
      other:
        harness: codex
        shaping: {model: gpt-5.6-sol, effort: low}
        developer: {model: gpt-5.6-sol, effort: low}
        reviewer: {model: gpt-5.6-terra, effort: medium}
        helpers:
          scout: {model: gpt-5.6-luna, effort: low}
          worker: {model: gpt-5.6-luna, effort: medium}
          expert: {model: gpt-5.6-sol, effort: medium}
    outer_resumptions: 2
    verification_retries: 2
    offline_retries: 4
    """
  end

  defp hooks_json do
    Jason.encode!(%{
      "hooks" => %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{
                "type" => "command",
                "command" =>
                  "python3 \"$(git rev-parse --show-toplevel)/.codex/hooks/verification_policy.py\""
              }
            ]
          }
        ]
      }
    })
  end

  defp lib_a_before do
    """
    defmodule A do
      @moduledoc false
      def cited_bytes, do: 1
    end
    """
  end

  defp lib_a_after do
    """
    defmodule A do
      @moduledoc false
      def cited_digest, do: 2
    end
    """
  end

  defp a_test do
    """
    defmodule ATest do
      use ExUnit.Case
      test "a works" do
        assert true
      end
    end
    """
  end

  defp live_x_test do
    """
    defmodule LiveXTest do
      use ExUnit.Case
      @moduletag :live
      test "live x" do
        assert true
      end
    end
    """
  end

  defp git!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end

  defp git_out(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end
end
