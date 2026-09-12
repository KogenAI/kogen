defmodule Kogen.ScenarioSemantic do
  @moduledoc false
  @scenario_ids ["installed-artifact", "role-routing", "git-status-readiness"]

  def scenario_ids, do: @scenario_ids

  # The live Reviewer owns this tiny fixture. Its Python probes are focused
  # commands only; none invokes a Kogen target, Stop hook, or Build.
  def write_fixture!(root, state) when state in [:incomplete, :corrected] do
    Enum.each(~w(bin config probes source), &File.mkdir_p!(Path.join(root, &1)))
    File.write!(Path.join(root, "source/kogen_tool.py"), "print('installed artifact ready')\n")
    File.write!(Path.join(root, "config/flags.baseline.json"), "{\"feature\": false}\n")
    File.write!(Path.join(root, "config/flags.json"), "{\"feature\": true}\n")

    File.write!(
      Path.join(root, "config/profiles.json"),
      "{\"developer\":{\"model\":\"astra\",\"effort\":\"low\"},\"reviewer\":{\"model\":\"terra\",\"effort\":\"medium\"},\"shaper\":{\"model\":\"luna\",\"effort\":\"high\"}}\n"
    )

    File.write!(Path.join(root, "probes/installed_artifact.py"), """
    import subprocess, sys
    sys.exit(0 if subprocess.check_output(["./bin/kogen-tool"], text=True).strip() == "installed artifact ready" else 1)
    """)

    File.write!(Path.join(root, "probes/role_routing.py"), """
    import json, subprocess, sys
    failed = False
    for role, profile in json.load(open("config/profiles.json")).items():
      command = ["./bin/route", role, profile["model"], profile["effort"]]
      # A route is a three-field profile tuple, not a permissive prefix.  Check
      # every valid tuple and generic malformed call classes independently so a
      # passing Developer claim cannot hide an accepting extra argument or a
      # missing/invalid profile field.
      invalid = [
        command + ["unexpected"],
        ["./bin/route"],
        ["./bin/route", role],
        ["./bin/route", role, profile["model"]],
        ["./bin/route", "invalid-role", profile["model"], profile["effort"]],
        ["./bin/route", role, "invalid-model", profile["effort"]],
        ["./bin/route", role, profile["model"], "invalid-effort"],
      ]
      failed |= subprocess.call(command) != 0 or any(subprocess.call(bad) == 0 for bad in invalid)
    sys.exit(1 if failed else 0)
    """)

    File.write!(Path.join(root, "probes/git_status_readiness.py"), """
    import json, os, pathlib, subprocess, sys, tempfile
    implementation = str(pathlib.Path("bin/readiness").resolve())
    failed = False
    for flag in ("assume-unchanged", "skip-worktree"):
      with tempfile.TemporaryDirectory(prefix="kogen-readiness-control-") as directory:
        root = pathlib.Path(directory)
        (root / "config").mkdir()
        config = root / "config/flags.json"
        config.write_text('seed')
        env = dict(os.environ, GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        def git(*args): return subprocess.check_output(['git', *args], cwd=root, env=env)
        git('init', '-q'); git('add', '-A'); git('commit', '-qm', 'baseline')
        git('update-index', '--' + flag, 'config/flags.json')
        config.write_text('user change hidden from status')
        assert git('status', '--porcelain') == b''
        before = (root / '.git/index').read_bytes()
        result = subprocess.run([implementation], cwd=root, capture_output=True)
        unchanged = before == (root / '.git/index').read_bytes()
        print(json.dumps({'flag':flag, 'exit_code':result.returncode, 'index_unchanged':unchanged}))
        failed |= result.returncode != 1 or not unchanged
    sys.exit(1 if failed else 0)
    """)

    File.write!(Path.join(root, "probes/claimed_evidence.py"), """
    import subprocess
    # Preserved failure pattern: copied source and partial settings look green.
    assert subprocess.check_output(['python3', 'source/kogen_tool.py'], text=True).strip() == 'installed artifact ready'
    assert subprocess.call(['./bin/route', 'developer', 'astra', 'low']) == 0
    print('copied-source and partial Developer setting checks pass; no installed-command or full invalid-config evidence')
    """)

    case state do
      :incomplete -> incomplete_fixture!(root)
      :corrected -> corrected_fixture!(root)
    end

    Enum.each(
      ~w(bin/kogen-tool bin/route bin/readiness),
      &File.chmod!(Path.join(root, &1), 0o755)
    )
  end

  def focused_probe!(root, name) when name in @scenario_ids do
    System.cmd("python3", ["probes/#{probe_name(name)}"], cd: root, stderr_to_stdout: true)
  end

  def handoff(attempt_token, state) when state in [:incomplete, :corrected] do
    %{
      "attempt_token" => attempt_token,
      "scenarios" =>
        Enum.map(
          @scenario_ids,
          fn id ->
            proof = if state == :incomplete, do: "claimed_evidence.py", else: probe_name(id)
            reference = %{"path" => "probes/#{proof}", "locator" => "line 1"}

            %{
              "id" => id,
              "status" => "ready",
              "claim" => "The referenced checks demonstrate #{id} is implemented.",
              "implementation" => [reference],
              "evidence" => [reference]
            }
          end
        ),
      "risks" => [],
      "findings" => []
    }
  end

  def review_response!(response, expected) when is_map(response) do
    require!(
      response["candidate_id"] == expected.candidate_id,
      "Reviewer response has the wrong candidate_id"
    )

    require!(
      response["attempt_token"] == expected.attempt_token,
      "Reviewer response has the wrong attempt_token"
    )

    require!(
      response["verdict"] in ["accept", "rework"],
      "Reviewer response has an invalid verdict"
    )

    scenarios = response["scenarios"]
    require!(is_list(scenarios), "Reviewer response must include scenarios")

    Enum.each(expected.scenario_ids, fn id ->
      scenario = Enum.find(scenarios, &(&1["id"] == id))
      require!(is_map(scenario), "Reviewer response is missing scenario #{id}")

      require!(
        scenario["status"] in ["satisfied", "needs_rework"],
        "Reviewer response has an invalid scenario status"
      )

      require!(
        nonblank?(scenario["reason"]),
        "Reviewer response needs a reason for scenario #{id}"
      )

      evidence!(scenario["evidence"], "scenario #{id}")
    end)

    findings = response["findings"]
    require!(is_list(response["dispositions"]), "Reviewer response must include dispositions")
    require!(is_list(findings), "Reviewer response must include findings")

    Enum.each(findings, fn finding ->
      require!(
        is_list(finding["scenario_ids"]) and finding["scenario_ids"] != [],
        "Reviewer finding needs scenario_ids"
      )

      require!(nonblank?(finding["reason"]), "Reviewer finding needs a reason")
      evidence!(finding["evidence"], "finding")
    end)

    statuses = Map.new(scenarios, &{&1["id"], &1["status"]})

    if response["verdict"] == "accept" do
      require!(
        Enum.all?(expected.scenario_ids, &(statuses[&1] == "satisfied")),
        "accepting Reviewer leaves a scenario unsatisfied"
      )

      require!(findings == [], "accepting Reviewer has open findings")
    else
      require!(
        Enum.any?(expected.scenario_ids, &(statuses[&1] == "needs_rework")),
        "rework Reviewer identifies no scenario needing rework"
      )

      require!(findings != [], "rework Reviewer has no actionable findings")
    end

    response
  end

  defp incomplete_fixture!(root) do
    File.write!(Path.join(root, "bin/kogen-tool"), "#!/bin/sh\necho legacy source copy\n")

    File.write!(
      Path.join(root, "bin/route"),
      "#!/bin/sh\n[ \"$#\" -eq 3 ] || exit 1\n[ \"$1:$2:$3\" = developer:astra:low ] && exit 0\nexit 1\n"
    )

    File.write!(
      Path.join(root, "bin/readiness"),
      "#!/bin/sh\ngit status --porcelain | grep -q . && exit 1\nexit 0\n"
    )
  end

  defp corrected_fixture!(root) do
    File.write!(
      Path.join(root, "bin/kogen-tool"),
      "#!/bin/sh\nexec python3 source/kogen_tool.py\n"
    )

    File.write!(
      Path.join(root, "bin/route"),
      "#!/bin/sh\n[ \"$#\" -eq 3 ] || exit 1\ncase \"$1:$2:$3\" in developer:astra:low|reviewer:terra:medium|shaper:luna:high) exit 0 ;; *) exit 1 ;; esac\n"
    )

    File.write!(
      Path.join(root, "bin/readiness"),
      "#!/bin/sh\nexec python3 -c 'import subprocess,sys; entries=subprocess.check_output([\"git\",\"ls-files\",\"-v\",\"-z\"]).split(bytes([0])); sys.exit(1 if any(e and (chr(e[0]).islower() or e[0] == 83) for e in entries) else 0)'\n"
    )
  end

  defp probe_name("installed-artifact"), do: "installed_artifact.py"
  defp probe_name("role-routing"), do: "role_routing.py"
  defp probe_name("git-status-readiness"), do: "git_status_readiness.py"

  defp evidence!(items, label) when is_list(items) and items != [],
    do:
      Enum.each(items, fn item ->
        require!(
          nonblank?(item["path"]) and nonblank?(item["locator"]),
          "Reviewer #{label} evidence needs a path and locator"
        )
      end)

  defp evidence!(_, label), do: fail!("Reviewer #{label} needs inspectable evidence")
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp require!(true, _), do: :ok
  defp require!(false, message), do: fail!(message)
  defp fail!(message), do: raise(ArgumentError, message)
end
