defmodule Kogen.WriteBoundaryTest do
  @moduledoc """
  The Build-wide role write boundary (BLD-12): the rendered profile and its
  grants, real `sandbox-exec` launches of fake roles through the Claude Code
  and Codex adapters in a hybrid Build, every refused and allowed write as
  the launched process saw it, the Codex scope denials, and every
  fail-closed and inherited case.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.WriteBoundary
  alias Kogen.CandidateFixture, as: Candidate
  alias Kogen.Harness.Codex, as: CodexHarness
  alias Kogen.WorkspaceFixture, as: Fixture

  @moduletag :unconfined
  @moduletag timeout: 300_000
  @slug Fixture.slug()

  defp dirs!(label, names) do
    base = Fixture.tmp_dir!(label)

    Map.new(names, fn name ->
      path = Path.join(base, Atom.to_string(name))
      File.mkdir_p!(path)
      {name, path}
    end)
    |> Map.put(:base, base)
  end

  describe "the rendered profile" do
    setup do
      d = dirs!("render", [:candidate, :home, :tmp, :control, :claude_scope, :codex_scope])
      %{d: d}
    end

    test "a Claude Code route grants the Candidate, harness home, temp dir, devices, keychain and the Claude refresh lock only",
         %{d: d} do
      {:ok, boundary} =
        WriteBoundary.prepare(%{
          candidate: d.candidate,
          harness_home: d.home,
          tmp_dir: d.tmp,
          control: d.control,
          claude_scope: d.claude_scope,
          keychain: nil
        })

      real = &WriteBoundary.canonical/1

      assert boundary.grants == %{
               candidate: real.(d.candidate),
               harness_home: real.(d.home),
               tmp_dir: real.(d.tmp),
               claude_lock: Path.join(real.(d.claude_scope), ".oauth_refresh.lock"),
               codex_scope: nil,
               keychain: nil
             }

      assert allowed(boundary.profile) == [
               ~s{(subpath "#{real.(d.candidate)}")},
               ~s{(subpath "#{real.(d.home)}")},
               ~s{(subpath "#{real.(d.tmp)}")},
               ~s{(subpath "#{real.(d.claude_scope)}/.oauth_refresh.lock")}
               | device_lines()
             ]

      assert boundary.profile =~ "(allow default)\n(deny file-write*)"
      assert boundary.profile =~ ~s{(allow process-exec (with no-sandbox) (literal "/bin/ps"))}
      assert boundary.profile =~ "(deny lsopen)"
      assert boundary.profile =~ "(deny appleevent-send)"
      refute boundary.profile =~ "codex"

      assert boundary.sha256 ==
               Base.encode16(:crypto.hash(:sha256, boundary.profile), case: :lower)
    end

    test "a Codex route grants its scope minus the refused and Kogen-owned entries", %{d: d} do
      {:ok, boundary} =
        WriteBoundary.prepare(%{
          candidate: d.candidate,
          harness_home: d.home,
          tmp_dir: d.tmp,
          control: d.control,
          codex_scope: d.codex_scope,
          keychain: nil
        })

      scope = WriteBoundary.canonical(d.codex_scope)
      assert boundary.grants.codex_scope == scope
      assert boundary.grants.claude_lock == nil
      assert ~s{(subpath "#{scope}")} in allowed(boundary.profile)

      literals =
        for name <- ~w(hooks.json AGENTS.md AGENTS.override.md environments.toml .kogen-owned),
            do: ~s{(literal "#{scope}/#{name}")}

      subpaths =
        for name <- ~w(plugins rules config.d agents), do: ~s{(subpath "#{scope}/#{name}")}

      denied = literals ++ subpaths

      assert denied(boundary.profile) == denied

      assert WriteBoundary.record_block(boundary)["denied_scope_entries"] ==
               ~w(hooks.json AGENTS.md AGENTS.override.md environments.toml .kogen-owned plugins rules config.d agents)
    end

    test "a hybrid route grants both the Claude refresh lock and the Codex scope", %{d: d} do
      {:ok, boundary} =
        WriteBoundary.prepare(%{
          candidate: d.candidate,
          harness_home: d.home,
          tmp_dir: d.tmp,
          control: d.control,
          claude_scope: d.claude_scope,
          codex_scope: d.codex_scope,
          keychain: nil
        })

      lines = allowed(boundary.profile)

      assert ~s{(subpath "#{WriteBoundary.canonical(d.claude_scope)}/.oauth_refresh.lock")} in lines

      assert ~s{(subpath "#{WriteBoundary.canonical(d.codex_scope)}")} in lines
      assert length(lines) == 5 + length(device_lines())
    end

    test "the login keychain file and its .sb- temp files are the one keychain grant", %{d: d} do
      keychain = Path.join(d.base, "login.keychain-db")
      File.write!(keychain, "")

      {:ok, boundary} =
        WriteBoundary.prepare(%{
          candidate: d.candidate,
          harness_home: d.home,
          tmp_dir: d.tmp,
          control: d.control,
          keychain: keychain
        })

      real = WriteBoundary.canonical(keychain)
      assert ~s{(literal "#{real}")} in allowed(boundary.profile)
      assert ~s{(prefix "#{real}.sb-")} in allowed(boundary.profile)
    end
  end

  describe "codex-roles-inside-boundary: scope denials" do
    test "refused Codex scope entries fail with EPERM, also by rename; rollouts and history succeed" do
      d = dirs!("codex-scope", [:candidate, :home, :tmp, :control, :scope])
      File.write!(Path.join(d.scope, "environments.toml"), "seeded\n")
      File.mkdir_p!(Path.join(d.scope, "agents"))
      File.write!(Path.join(d.scope, "agents/kogen_boundary.toml"), "seeded\n")
      File.write!(Path.join(d.scope, ".kogen-owned"), "account-v1\n")
      File.write!(Path.join(d.scope, "auth.json"), "{}\n")
      File.write!(Path.join(d.candidate, "staged-hooks.json"), "{}\n")
      before = snapshot(d.scope)

      {:ok, boundary} =
        WriteBoundary.prepare(%{
          candidate: d.candidate,
          harness_home: d.home,
          tmp_dir: d.tmp,
          control: d.control,
          codex_scope: d.scope,
          keychain: nil
        })

      scope = WriteBoundary.canonical(d.scope)

      script = ~S"""
      cd "$1"; s="$2"; c="$3"
      try() { name="$1"; shift; if "$@" 2>/dev/null; then echo "$name=ok"; else echo "$name=refused"; fi; }
      try rollout sh -c "mkdir -p '$s/sessions' && echo r > '$s/sessions/rollout.jsonl'"
      try history sh -c "echo h >> '$s/history.jsonl'"
      try config sh -c "echo 'k=1' >> '$s/config.toml'"
      try auth_refresh sh -c "echo '{\"t\":1}' > '$s/auth.json.tmp' && mv '$s/auth.json.tmp' '$s/auth.json'"
      try hooks sh -c "echo x > '$s/hooks.json'"
      try hooks_rename mv "$c/staged-hooks.json" "$s/hooks.json"
      try plugins mkdir "$s/plugins"
      try rules mkdir "$s/rules"
      try config_d mkdir "$s/config.d"
      try agents_md sh -c "echo x > '$s/AGENTS.md'"
      try agents_override sh -c "echo x > '$s/AGENTS.override.md'"
      try environments sh -c "echo x > '$s/environments.toml'"
      try environments_rename mv "$s/environments.toml" "$s/environments.moved"
      try agents_file sh -c "echo x > '$s/agents/kogen_boundary.toml'"
      try agents_rename mv "$s/agents" "$s/agents.moved"
      try owned_delete rm "$s/.kogen-owned"
      """

      [exe | args] =
        WriteBoundary.prefix(boundary) ++
          ["/bin/sh", "-c", script, "sh", d.candidate, scope, d.candidate]

      {out, 0} = System.cmd(exe, args, stderr_to_stdout: true)

      outcome =
        out |> String.split("\n", trim: true) |> Map.new(&List.to_tuple(String.split(&1, "=")))

      for allowed <- ~w(rollout history config auth_refresh),
          do: assert(outcome[allowed] == "ok", allowed)

      for denied <-
            ~w(hooks hooks_rename plugins rules config_d agents_md agents_override environments environments_rename agents_file agents_rename owned_delete),
          do: assert(outcome[denied] == "refused", denied)

      after_ = snapshot(d.scope)

      for name <-
            ~w(hooks.json plugins rules config.d AGENTS.md AGENTS.override.md environments.moved agents.moved) do
        refute Map.has_key?(after_, name), name
      end

      assert after_["environments.toml"] == before["environments.toml"]
      assert after_[".kogen-owned"] == before[".kogen-owned"]
    end

    # Codex's own Seatbelt cannot nest inside the boundary, so the kernel
    # profile is the enforcement.
    test "Codex launches keep both bypass flags and a second profile cannot nest" do
      for args <- [
            CodexHarness.developer_args("m", "low"),
            CodexHarness.developer_args("m", "low", "session"),
            CodexHarness.reviewer_args("m", "low"),
            CodexHarness.expert_args("m", "low")
          ] do
        assert "--dangerously-bypass-approvals-and-sandbox" in args
        assert "--dangerously-bypass-hook-trust" in args
      end

      d = dirs!("codex-nest", [:candidate, :home, :tmp, :control])

      {:ok, boundary} =
        WriteBoundary.prepare(%{
          candidate: d.candidate,
          harness_home: d.home,
          tmp_dir: d.tmp,
          control: d.control,
          keychain: nil
        })

      # Any other profile, like the one Codex's own sandbox would apply,
      # fails to nest inside the boundary.
      [exe | args] =
        WriteBoundary.prefix(boundary) ++
          [
            "/usr/bin/sandbox-exec",
            "-p",
            "(version 1)(allow default)(deny network*)",
            "/usr/bin/true"
          ]

      assert {out, 71} = System.cmd(exe, args, stderr_to_stdout: true)
      assert out =~ "sandbox_apply"
    end
  end

  describe "role-write-boundary: a hybrid Build's fake roles" do
    setup do
      if Fixture.isolated_child?(),
        do: hybrid_boundary_build(),
        else:
          Map.new(~w(control result record receipts before refs raw sentinel other)a, &{&1, nil})
    end

    defp hybrid_boundary_build do
      control =
        Fixture.create!(route: :hybrid, guards: ["dummy.txt", "reviewer-rework-marker.txt"])

      claude_root = Fixture.claude_root!()
      File.write!(Path.join(claude_root, "accounts/shared/settings.json"), "{}\n")
      File.mkdir_p!(Path.join(control, ".kogen/runtime/boundary-escape"))
      raw = Path.join(control, ".kogen/runtime/controller-raw-log")
      File.mkdir_p!(raw)
      sentinel = Fixture.tmp_dir!("boundary-sentinel")
      File.write!(Path.join(sentinel, "keep"), "sentinel\n")

      # A second, retained Candidate of this project and its harness home.
      failing =
        Fixture.fake!(
          Fixture.tmp_dir!("failing"),
          "failing",
          "#!/bin/sh\n[ \"$1\" = auth ] && exec #{inspect(Fixture.support("fake_claude"))} \"$@\"\nexit 3\n"
        )

      assert {:error, _} =
               Fixture.build!(control,
                 harness: failing,
                 env: [{"KOGEN_CLAUDE_ROOT", claude_root}]
               )

      other = Candidate.candidate(control)
      tmp_alias = "/tmp/" <> Path.basename(sentinel)
      File.ln_s!(sentinel, tmp_alias)
      on_exit(fn -> File.rm(tmp_alias) end)

      protected =
        [
          Path.join(control, "README.md"),
          Path.join(control, ".kogen/build.lock"),
          Path.join(control, ".git/config"),
          Path.join(control, ".git/HEAD"),
          other["owner_record"],
          Path.join(claude_root, "accounts/shared/settings.json"),
          Path.join(sentinel, "keep")
        ]

      before = Map.new(protected, &{&1, digest(&1)})
      refs = Fixture.git!(control, ["show-ref"])

      env = [
        {"KOGEN_CLAUDE_ROOT", claude_root},
        {"KOGEN_RAW_LOG_DIR", raw},
        {"FIXTURE_NEXT_ROLE", Fixture.support("fake_hybrid")},
        {"FIXTURE_CONTROL", control},
        {"FIXTURE_CONTROLLER_RAW_LOG", raw},
        {"FIXTURE_OTHER_CANDIDATE", other["worktree_path"]},
        {"FIXTURE_OTHER_HOME", other["harness_home"]},
        {"FIXTURE_OWNER_RECORD", other["owner_record"]},
        {"FIXTURE_CLAUDE_SETTINGS", Path.join(claude_root, "accounts/shared/settings.json")},
        {"FIXTURE_SENTINEL", sentinel},
        {"FIXTURE_TMP_ALIAS", tmp_alias},
        {"FIXTURE_PROBE_SERVICES", "1"}
      ]

      result = Fixture.build!(control, harness: Fixture.support("fake_boundary_role"), env: env)
      record = Candidate.record(control)

      %{
        control: control,
        result: result,
        record: record,
        receipts: boundary_receipts(record["candidate"]["harness_home"]),
        before: before,
        refs: refs,
        raw: raw,
        sentinel: sentinel,
        other: other
      }
    end

    test "the Build is accepted and published although every role ran inside the boundary",
         %{result: result, record: record} do
      assert result == :ok
      assert record["candidate"]["disposition"] == "published"
    end

    test "every model launch ran confined in the Candidate with the record's profile sha256",
         %{record: record, receipts: receipts} do
      sha = record["boundary"]["profile_sha256"]
      assert record["boundary"]["mode"] == "applied"
      roles = Enum.map(receipts, & &1["role"])
      assert Enum.count(roles, &(&1 == "developer")) == 3
      assert Enum.count(roles, &(&1 == "reviewer")) == 2

      for receipt <- receipts do
        assert receipt["write_boundary"] == sha
        assert receipt["pwd"] == record["candidate"]["worktree_path"]
        assert receipt["results"]["nested_sandbox"]["exit"] == 71
        assert receipt["tmpdir"] == record["boundary"]["grants"]["tmp_dir"]
      end

      for receipt <- Candidate.receipts(record["candidate"]["control_root"]) do
        assert receipt["env"]["KOGEN_WRITE_BOUNDARY"] == sha
      end
    end

    test "writes into the Candidate, the harness home and the temp dir succeed, from the role, a helper child and a make grandchild",
         %{receipts: receipts} do
      for receipt <- receipts do
        results = receipt["results"]
        assert results["home_write"]["ok"], inspect(results["home_write"])
        assert results["tmp_write"]["ok"], inspect(results["tmp_write"])
        assert results["helper_child_inside"]["ok"], inspect(results["helper_child_inside"])
        assert results["make_grandchild_inside"]["ok"], inspect(results["make_grandchild_inside"])

        if receipt["role"] == "developer",
          do: assert(results["candidate_write"]["ok"], inspect(results["candidate_write"])),
          else: refute(Map.has_key?(results, "candidate_write"))
      end
    end

    # Control, its .kogen and lock, its Git metadata, the controller raw log,
    # another Candidate and its home, an owner record, the Claude scope, the
    # sentinel and its /tmp alias.
    test "every outside write fails with EPERM and leaves nothing behind",
         %{receipts: receipts} do
      python_writes =
        ~w(control_create control_append control_delete control_rename control_chmod control_kogen control_lock controller_raw_log other_candidate other_harness_home owner_record claude_scope_settings sentinel tmp_alias)

      for receipt <- receipts, name <- python_writes do
        result = receipt["results"][name]
        refute result["ok"], "#{receipt["role"]} #{name} succeeded"
        assert result["errno"] == "EPERM", "#{receipt["role"]} #{name}: #{inspect(result)}"
      end

      for receipt <- receipts,
          receipt["role"] == "developer",
          name <- ~w(control_hardlink control_symlink_follow) do
        assert receipt["results"][name]["errno"] == "EPERM",
               "#{name}: #{inspect(receipt["results"][name])}"
      end

      for receipt <- receipts,
          name <-
            ~w(git_commit git_candidate_commit git_update_ref git_config make_grandchild_outside) do
        result = receipt["results"][name]
        refute result["ok"], "#{receipt["role"]} #{name} succeeded"
        assert result["stderr"] =~ "Operation not permitted", "#{name}: #{inspect(result)}"
      end
    end

    test "a background child that outlives its role is still refused", %{receipts: receipts} do
      for receipt <- receipts do
        path = receipt["results"]["background_child"]["result_path"]
        assert wait_for(path) == "1\n", "background child of #{receipt["role"]} was not refused"
      end
    end

    test "LaunchServices opens and Apple Events are denied", %{receipts: receipts} do
      for receipt <- receipts do
        refute receipt["results"]["lsopen"]["ok"], inspect(receipt["results"]["lsopen"])
        refute receipt["results"]["appleevent"]["ok"], inspect(receipt["results"]["appleevent"])
      end
    end

    test "every protected path keeps its bytes and no attempted outside file or ref exists",
         %{
           control: control,
           before: before,
           refs: refs,
           sentinel: sentinel,
           raw: raw,
           other: other
         } do
      for {path, digest} <- before, do: assert(digest(path) == digest, path)

      published_refs =
        Fixture.git!(control, ["show-ref"])
        |> String.split("\n")
        |> Enum.reject(&String.ends_with?(&1, "refs/heads/main"))

      expected_refs =
        refs |> String.split("\n") |> Enum.reject(&String.ends_with?(&1, "refs/heads/main"))

      assert published_refs == expected_refs
      refute Fixture.git!(control, ["config", "--list"]) =~ "boundaryescape"
      assert Path.wildcard(Path.join(control, "boundary-*")) == []
      assert File.ls!(Path.join(control, ".kogen/runtime/boundary-escape")) == []
      assert Path.wildcard(Path.join(sentinel, "*")) == [Path.join(sentinel, "keep")]
      assert Path.wildcard(Path.join(other["worktree_path"], "escape-*")) == []
      assert Path.wildcard(Path.join(other["harness_home"], "escape-*")) == []
      assert Path.wildcard(Path.join(raw, "escape-*")) == []
      assert File.read!(Path.join(control, "README.md")) == "control sentinel\n"
    end

    test "the tracking record's boundary block names mode applied, the profile sha256, the grant list and the sandbox-exec path",
         %{record: record} do
      block = record["boundary"]
      candidate = record["candidate"]
      assert block["mode"] == "applied"
      assert block["profile_sha256"] =~ ~r/^[0-9a-f]{64}$/
      assert block["sandbox_exec"] == "/usr/bin/sandbox-exec"
      assert block["grants"]["candidate"] == candidate["worktree_path"]
      assert block["grants"]["harness_home"] == candidate["harness_home"]
      assert block["grants"]["tmp_dir"] =~ ~r{/kogen-build-[A-Za-z0-9_-]+$}
      refute block["grants"]["tmp_dir"] =~ " "
      assert block["grants"]["claude_lock"] =~ ~r{/accounts/shared/\.oauth_refresh\.lock$}
      refute Map.has_key?(block["grants"], "codex_scope")
      assert block["denied_scope_entries"] == []
    end

    test "the controller's raw log is not granted; roles log to the harness home, which the controller copies at exit",
         %{record: record, raw: raw} do
      notes = Path.wildcard(Path.join([raw, "boundary-role-note-*"]))
      assert length(notes) == 5
      assert File.dir?(Path.join(record["candidate"]["harness_home"], "raw-log"))

      refute File.exists?(record["boundary"]["grants"]["tmp_dir"]),
             "the temp dir is removed at exit"
    end
  end

  describe "write-boundary-fails-closed" do
    setup do
      control = Fixture.create!(route: :claude)
      %{control: control, claude_root: Fixture.claude_root!()}
    end

    test "a missing sandbox-exec stops before any readiness call or launch, naming the path, with the Candidate kept",
         %{control: control, claude_root: claude_root} do
      Application.put_env(:kogen, :sandbox_exec, "/nonexistent/sandbox-exec")

      assert {:error, reason} =
               Fixture.build!(control,
                 harness: Fixture.support("fake_claude"),
                 env: [{"KOGEN_CLAUDE_ROOT", claude_root}]
               )

      Application.delete_env(:kogen, :sandbox_exec)
      assert reason =~ "write boundary unavailable: /nonexistent/sandbox-exec is missing"
      assert_no_launch_and_kept(control, reason)
    end

    test "a failed admission self-test stops before any readiness call or launch", %{
      control: control,
      claude_root: claude_root
    } do
      fake = Fixture.tmp_dir!("fake-sandbox-exec")

      # Unconfined for the kernel probe, but refusing the rendered profile.
      exe =
        Fixture.fake!(fake, "sandbox-exec", """
        #!/bin/sh
        [ "$2" = "(version 1)(allow default)" ] && exec /usr/bin/true
        echo 'sandbox_apply: rendered profile refused' >&2
        exit 65
        """)

      Application.put_env(:kogen, :sandbox_exec, exe)

      assert {:error, reason} =
               Fixture.build!(control,
                 harness: Fixture.support("fake_claude"),
                 env: [{"KOGEN_CLAUDE_ROOT", claude_root}]
               )

      Application.delete_env(:kogen, :sandbox_exec)
      assert reason =~ "write boundary admission self-test failed (#{exe} exit 65)"
      assert_no_launch_and_kept(control, reason)
    end

    test "a workspaces root inside the control checkout is a forbidden grant and stops before any launch",
         %{control: control, claude_root: claude_root} do
      assert {:error, reason} =
               Fixture.build!(control,
                 harness: Fixture.support("fake_claude"),
                 env: [
                   {"KOGEN_CLAUDE_ROOT", claude_root},
                   {"KOGEN_WORKSPACES_ROOT",
                    Path.join(control, ".kogen/runtime/nested workspaces")}
                 ]
               )

      assert reason =~ "write boundary refused the candidate grant"
      assert reason =~ "it is inside the control root"
      refute reason =~ "harness failure"
    end

    test "a workspaces root given through the /tmp alias is rendered from its canonical /private/tmp path and roles write inside",
         %{control: control, claude_root: claude_root} do
      name = "kogen-alias-#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join("/private/tmp", name))
      on_exit(fn -> File.rm_rf(Path.join("/private/tmp", name)) end)

      assert :ok =
               Fixture.build!(control,
                 harness: Fixture.support("fake_claude"),
                 env: [
                   {"KOGEN_CLAUDE_ROOT", claude_root},
                   {"KOGEN_WORKSPACES_ROOT", Path.join("/tmp", name)}
                 ]
               )

      record = Candidate.record(control)
      grants = record["boundary"]["grants"]
      assert String.starts_with?(grants["candidate"], "/private/tmp/#{name}/")
      assert String.starts_with?(grants["harness_home"], "/private/tmp/#{name}/")
      refute Enum.any?(Map.values(grants), &String.starts_with?(&1, "/tmp/"))
      assert Candidate.receipts(control, "developer", []) != []
    end

    test "an unresolvable grant and each forbidden grant are refused, naming the reason and the path" do
      d = dirs!("forbidden", [:candidate, :home, :tmp, :control])

      input = %{
        candidate: d.candidate,
        harness_home: d.home,
        tmp_dir: d.tmp,
        control: d.control,
        keychain: nil
      }

      missing = Path.join(d.base, "missing")

      assert {:error, reason} = WriteBoundary.prepare(%{input | candidate: missing})
      assert reason =~ "cannot be resolved to an existing directory: #{missing}"

      home = WriteBoundary.canonical(System.user_home!())
      control = WriteBoundary.canonical(d.control)

      for {grant, why} <- [
            {"/", "it is a system root"},
            {"/private/tmp", "it is a system root"},
            {"/private/var", "it is a system root"},
            {home, "it is $HOME"},
            {control, "it is the control root"},
            {Path.dirname(control), "it is an ancestor of the control root"}
          ] do
        assert {:error, reason} = WriteBoundary.prepare(%{input | tmp_dir: grant})
        assert reason =~ "write boundary refused the tmp_dir grant #{grant}: #{why}"
      end
    end

    test "an unconfined controller ignores a spoofed KOGEN_WRITE_BOUNDARY and applies its own profile",
         %{control: control, claude_root: claude_root} do
      assert :ok =
               Fixture.build!(control,
                 harness: Fixture.support("fake_claude"),
                 env: [{"KOGEN_CLAUDE_ROOT", claude_root}, {"KOGEN_WRITE_BOUNDARY", "spoofed"}]
               )

      block = Candidate.record(control)["boundary"]
      assert block["mode"] == "applied"
      refute block["profile_sha256"] == "spoofed"

      for receipt <- Candidate.receipts(control),
          do: assert(receipt["env"]["KOGEN_WRITE_BOUNDARY"] == block["profile_sha256"])
    end

    test "the harness home's raw log is copied into the controller's KOGEN_RAW_LOG_DIR at exit, on success and on a stop",
         %{control: control, claude_root: claude_root} do
      raw = Fixture.tmp_dir!("controller-raw")

      env = [
        {"KOGEN_CLAUDE_ROOT", claude_root},
        {"KOGEN_RAW_LOG_DIR", raw},
        {"FIXTURE_NEXT_ROLE", Fixture.support("fake_claude")}
      ]

      assert :ok =
               Fixture.build!(control, harness: Fixture.support("fake_boundary_role"), env: env)

      assert Path.wildcard(Path.join(raw, "boundary-role-note-*")) != []

      stopped = Fixture.tmp_dir!("controller-raw-stop")
      Fixture.write_intent!(control, "stops")

      stop_env =
        env
        |> List.keystore("KOGEN_RAW_LOG_DIR", 0, {"KOGEN_RAW_LOG_DIR", stopped})
        |> List.keystore("FAKE_CHECK_FAIL_ALWAYS", 0, {"FAKE_CHECK_FAIL_ALWAYS", "1"})

      assert {:error, reason} =
               Fixture.build!(control,
                 slug: "stops",
                 harness: Fixture.support("fake_boundary_role"),
                 env: stop_env
               )

      assert reason =~ "verification retries exhausted"

      assert Path.wildcard(Path.join(stopped, "boundary-role-note-*")) != []
    end
  end

  describe "write-boundary-fails-closed: a controller already inside a sandbox" do
    setup do
      outer = dirs!("outer", [:workspaces, :tmp, :sentinel])
      control = Fixture.create!()
      File.mkdir_p!(Path.join(control, ".kogen/runtime"))

      {:ok, boundary} =
        WriteBoundary.prepare(%{
          candidate: control,
          harness_home: outer.workspaces,
          tmp_dir: outer.tmp,
          control: Fixture.tmp_dir!("outer-control"),
          keychain: nil
        })

      %{outer: outer, control: control, boundary: boundary}
    end

    # Its roles are KOGEN_HARNESS test executables; they still cannot write
    # outside the enclosing grants.
    test "with the marker, a fixture Build runs inherited and stays bounded by the enclosing profile",
         %{outer: outer, control: control, boundary: boundary} do
      {output, status} =
        confined_build(control, boundary, outer, [
          {"KOGEN_WRITE_BOUNDARY", boundary.sha256},
          {"FIXTURE_NEXT_ROLE", Fixture.support("fake_codex_simple_accept")},
          {"FIXTURE_SENTINEL", outer.sentinel}
        ])

      assert status == 0, output
      record = Candidate.record(control)
      assert record["boundary"]["mode"] == "inherited"
      assert record["boundary"]["profile_sha256"] == boundary.sha256
      [receipt | _] = boundary_receipts(record["candidate"]["harness_home"])
      assert receipt["results"]["sentinel"]["errno"] == "EPERM"
      assert receipt["results"]["home_write"]["ok"]
      assert File.ls!(outer.sentinel) == []
    end

    test "without the marker (a foreign sandbox), the Build stops before admission naming it",
         %{outer: outer, control: control, boundary: boundary} do
      {output, status} = confined_build(control, boundary, outer, [{"KOGEN_WRITE_BOUNDARY", nil}])
      assert status != 0
      assert output =~ "a Build cannot start inside a foreign sandbox"
      assert Candidate.records(control) == []
    end

    test "a confined Build whose roles use a managed runtime stops before admission",
         %{outer: outer, control: control, boundary: boundary} do
      claude_root = Fixture.claude_root!()
      File.write!(Path.join(control, ".kogen/config.yaml"), claude_config())
      Fixture.git!(control, ["commit", "-q", "-am", "claude route"])

      {output, status} =
        confined_build(control, boundary, outer, [
          {"KOGEN_WRITE_BOUNDARY", boundary.sha256},
          {"KOGEN_HARNESS", nil},
          {"KOGEN_CLAUDE_ROOT", claude_root}
        ])

      assert status != 0
      assert output =~ "a Build cannot start inside another Build's role boundary"
      assert Candidate.records(control) == []
    end
  end

  # `mix kogen.build` in a subprocess confined by an outer profile that
  # grants the fixture control, a workspaces root and a temp dir.
  defp confined_build(control, boundary, outer, env) do
    ebins =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(
        &(Path.type(&1) == :absolute and Path.basename(&1) == "ebin" and File.dir?(&1))
      )

    base = [
      {"MIX_BUILD_PATH", Path.join(control, "_build")},
      {"KOGEN_WORKSPACES_ROOT", outer.workspaces},
      {"TMPDIR", outer.tmp},
      {"KOGEN_HARNESS", Fixture.support("fake_boundary_role")},
      {"KOGEN_JEV_TRANSPORT", Fixture.support("fake_jev")},
      {"KOGEN_JEV_SECURITY", Fixture.support("fake_security")},
      {"FAKE_JEV_LOG_DIR", Path.join(outer.tmp, "fake-jev")}
    ]

    env = Enum.reduce(env, base, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end)

    System.cmd(
      "/usr/bin/sandbox-exec",
      ["-p", boundary.profile, System.find_executable("elixir")] ++
        Enum.flat_map(ebins, &["-pa", &1]) ++ ["-S", "mix", "kogen.build", @slug],
      cd: control,
      env: env ++ Fixture.git_identity(),
      stderr_to_stdout: true
    )
  end

  defp claude_config do
    """
    default_route: claude
    routes:
      claude:
        harness: claude
        shaping:   {model: claude-opus-5-5, effort: medium}
        developer: {model: claude-opus-5-5, effort: medium}
        reviewer:  {model: claude-opus-5-5, effort: medium}
        helpers:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
          expert: {model: claude-opus-5-5, effort: high}
    outer_resumptions: 2
    verification_retries: 2
    """
  end

  defp assert_no_launch_and_kept(control, reason) do
    record = Candidate.record(control)
    block = record["candidate"]
    assert reason =~ "Candidate kept"
    assert block["disposition"] == "retained"
    assert File.dir?(block["worktree_path"])
    assert Candidate.receipts(control) == [], "no readiness call or role launch may happen"
    refute Map.has_key?(record, "boundary")
    [owner] = Fixture.owner_records(control)
    assert owner["status"] == "stopped: write-boundary"
  end

  defp boundary_receipts(home) do
    home
    |> Path.join("boundary-receipts/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(File.read!(&1) |> Jason.decode!()))
  end

  # The indented lines of the profile's `(allow file-write*` block, without
  # the block's closing parenthesis.
  defp allowed(profile), do: block_lines(profile, "(allow file-write*")

  # The indented lines of the Codex scope's `(deny file-write*` block.
  defp denied(profile) do
    profile
    |> String.split("(deny file-write*)", parts: 2)
    |> List.last()
    |> block_lines("(deny file-write*")
  end

  defp block_lines(profile, header) do
    profile
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != header))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, "  "))
    |> Enum.map(&String.trim/1)
    |> List.update_at(-1, &String.replace_suffix(&1, "))", ")"))
  end

  defp device_lines do
    Enum.map(~w(/dev/null /dev/zero /dev/tty /dev/ptmx /dev/dtracehelper), &~s{(literal "#{&1}")}) ++
      [~s{(regex #"^/dev/fd/[0-9]+$")}, ~s{(regex #"^/dev/ttys[0-9]+$")}]
  end

  defp snapshot(dir) do
    dir
    |> File.ls!()
    |> Map.new(fn name ->
      path = Path.join(dir, name)
      {name, if(File.regular?(path), do: File.read!(path), else: :directory)}
    end)
  end

  defp digest(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, reason} -> reason
    end
  end

  defp wait_for(path, attempts \\ 100) do
    case File.read(path) do
      {:ok, bytes} ->
        bytes

      {:error, _} when attempts > 0 ->
        Process.sleep(100)
        wait_for(path, attempts - 1)

      {:error, reason} ->
        reason
    end
  end
end
