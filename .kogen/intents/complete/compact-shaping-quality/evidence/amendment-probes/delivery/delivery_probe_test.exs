Code.require_file(Path.join(File.cwd!(), "test/support/compiled_fixture.exs"))
defmodule Kogen.AmendmentDeliveryProbe do
  use ExUnit.Case, async: true
  @out Path.join(File.cwd!(), ".kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/delivery")
  test "public startup exposes ordinary request before first executor observation and rejects missing request" do
    for supplied <- [true, false] do
      fixture = Kogen.CompiledFixture.create!(File.cwd!(), "amendment-delivery")
      on_exit(fn -> File.rm_rf(fixture) end)
      System.cmd("git", ["init", "-b", "main"], cd: fixture)
      System.cmd("git", ["config", "user.email", "fixture@example.invalid"], cd: fixture)
      System.cmd("git", ["config", "user.name", "Fixture"], cd: fixture)
      brief = "# Fixture\nCurrent user request: shape normalize INPUT OUTPUT; use slug eval-csv-complete; save the Draft without approval.\n"
      File.write!(Path.join(fixture, "README.md"), if(supplied, do: brief, else: "# Neutral fixture\n"))
      System.cmd("git", ["add", "."], cd: fixture)
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "fixture"], cd: fixture)
      fake = Path.join(fixture, "observe-first.py")
      File.write!(fake, """
      #!/usr/bin/env python3
      import sys,json,hashlib
      from pathlib import Path
      text=Path('README.md').read_text()
      supplied='save the Draft without approval' in text
      policy=sys.argv[-1]
      Path('observation.json').write_text(json.dumps({'supplied_before_executor_observation':supplied,'readme_sha256':hashlib.sha256(text.encode()).hexdigest(),'request_in_policy': 'Current user request:' in policy}))
      sys.exit(0 if supplied else 42)
      """)
      File.chmod!(fake, 0o755)
      {_, code} = Kogen.CompiledFixture.mix_task!(fixture, "kogen.shape", [{"KOGEN_HARNESS", fake}])
      assert code == if(supplied, do: 0, else: 42)
      observed = Jason.decode!(File.read!(Path.join(fixture, "observation.json")))
      assert observed["supplied_before_executor_observation"] == supplied
      refute observed["request_in_policy"]
      name = if supplied, do: "before-start-positive.json", else: "missing-request-negative.json"
      File.write!(Path.join(@out, name), Jason.encode!(observed, pretty: true))
    end
  end
end
