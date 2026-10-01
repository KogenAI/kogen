defmodule Kogen.ProjectChecksTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.{VerificationPlan, VerificationRunner}
  alias Kogen.Check

  test "separate projects own ordered checks and local readiness commands" do
    first = project_root!()
    second = project_root!()
    create_project!(first, "unit")
    create_project!(second, "lint")
    File.mkdir_p!(Path.join(first, "test"))
    File.write!(Path.join(first, "test/unit_test.exs"), "# selector\n")

    assert {:ok, first_catalog} = VerificationPlan.load(first)
    assert {:ok, second_catalog} = VerificationPlan.load(second)
    assert first_catalog.ordered_targets == ["unit"]
    assert second_catalog.ordered_targets == ["lint"]
    assert first_catalog.sha256 != second_catalog.sha256
    assert first_catalog.commands_sha256 != second_catalog.commands_sha256
    assert first_catalog.integrity == nil

    assert first_catalog.path ==
             Kogen.ProjectScope.canonical(Path.join([first, ".kogen", "project.yaml"]))

    assert first_catalog.bytes == File.read!(first_catalog.path)

    assert first_catalog.sha256 ==
             :crypto.hash(:sha256, first_catalog.bytes) |> Base.encode16(case: :lower)

    assert first_catalog.targets["unit"]["owner"] == "project"
    assert first_catalog.targets["unit"]["depends_on"] == []
    refute first_catalog.targets["unit"]["provider_backed"]

    assert :ok = Check.validate_targets(["unit"], Path.join(first, "Makefile"))

    assert {:error, "undeclared project check: lint"} =
             Check.validate_targets(["lint"], Path.join(first, "Makefile"))

    scenario = %{
      "id" => "unit-proof",
      "verified_by" => ["unit"],
      "proof" => %{
        "paid_target" => "none",
        "paid_reason" => "offline-sufficient: configured project check",
        "offline" => ["test/unit_test.exs"],
        "affected_paths" => ["src/app.ex"],
        "base" => nil
      }
    }

    assert {:ok, plan} = VerificationPlan.build([scenario], ["src/**"], first_catalog, first)
    assert plan.login_roles == []
    assert [command] = VerificationPlan.readiness_commands(plan, ["src/app.ex"], first)
    executable = Kogen.ProjectScope.canonical(Path.join(first, "scripts/check.sh"))
    assert command == "'#{executable}'"
    refute command =~ "mix format"
  end

  test "a missing declared setup dependency refuses project checks" do
    root = project_root!()
    create_project!(root, "unit")

    write_project_config!(
      root,
      "setup:\n" <>
        "  argv: [mise, install]\n" <>
        "  requires:\n" <>
        "    - executable: kogen-missing-prerequisite-4f0c3d\n" <>
        "checks:\n" <>
        "  - name: unit\n" <>
        "    argv: [./scripts/check.sh]\n"
    )

    assert {:error, reason} = VerificationPlan.load(root)
    assert reason =~ "missing project prerequisite"
    assert reason =~ "kogen-missing-prerequisite-4f0c3d"
  end

  test "frozen project argv rebinds to the Candidate's executable" do
    control = project_root!()
    candidate = project_root!()
    create_project!(control, "unit", "printf 'control copy\\n'\n")
    assert {:ok, catalog} = VerificationPlan.load(control)

    assert {:error, unavailable} = VerificationPlan.command(catalog, "unit", candidate)
    assert unavailable =~ "Candidate project executable is unavailable"

    write_executable!(candidate, "printf 'candidate copy\\n'\n")

    assert {:ok, argv} = VerificationPlan.command(catalog, "unit", candidate)
    assert argv == [Kogen.ProjectScope.canonical(Path.join(candidate, "scripts/check.sh"))]

    log = Path.join(candidate, "success.log")

    assert {:ok, facts} =
             VerificationRunner.run_target(candidate, "unit", log, argv: argv, timeout_ms: 5_000)

    assert VerificationRunner.status(facts) == "passed"
    assert facts["exit_code"] == 0
    assert File.read!(log) =~ "candidate copy"
    refute File.read!(log) =~ "control copy"

    outside = project_root!()
    write_executable!(outside, "printf 'outside copy\\n'\n")
    candidate_executable = Path.join(candidate, "scripts/check.sh")
    File.rm!(candidate_executable)
    File.ln_s!(Path.join(outside, "scripts/check.sh"), candidate_executable)
    assert {:error, reason} = VerificationPlan.command(catalog, "unit", candidate)
    assert reason =~ "escapes its checkout"
  end

  test "a failed project command keeps its failed runner receipt" do
    control = project_root!()
    candidate = project_root!()
    create_project!(control, "unit")
    write_executable!(candidate, "printf 'expected failure\\n' >&2\nexit 17\n")
    assert {:ok, catalog} = VerificationPlan.load(control)
    assert {:ok, argv} = VerificationPlan.command(catalog, "unit", candidate)

    log = Path.join(candidate, "failure.log")

    assert {:ok, facts} =
             VerificationRunner.run_target(candidate, "unit", log, argv: argv, timeout_ms: 5_000)

    assert facts["exit_code"] == 17
    assert VerificationRunner.status(facts) == "failed"
    assert File.read!(log) =~ "expected failure"
    assert facts["log_path"] == Path.expand(log)

    assert facts["log_sha256"] ==
             :crypto.hash(:sha256, File.read!(log)) |> Base.encode16(case: :lower)
  end

  defp project_root! do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    root = Path.join(System.tmp_dir!(), "kogen-project-checks-#{suffix}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {output, 0} = System.cmd("git", ["init", "--quiet", root], stderr_to_stdout: true)
    assert output == ""
    root
  end

  defp create_project!(root, name, script_body \\ "printf 'project check\\n'\n") do
    write_executable!(root, script_body)

    write_project_config!(
      root,
      "checks:\n" <>
        "  - name: #{name}\n" <>
        "    argv: [./scripts/check.sh]\n"
    )
  end

  defp write_project_config!(root, contents) do
    path = Path.join([root, ".kogen", "project.yaml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp write_executable!(root, body) do
    path = Path.join([root, "scripts", "check.sh"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end
end
