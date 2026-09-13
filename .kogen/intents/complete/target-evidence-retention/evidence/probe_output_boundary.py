"""Run from the Kogen repository root; creates only owned temporary probe files."""
from pathlib import Path
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix="kogen-evidence-shaping-") as directory:
    root = Path(directory)
    child = root / "emitter.exs"
    child.write_text('''defmodule ShapingEvidenceEmitter do
  use Kogen.IsolatedCase, async: true
  test "emits evidence" do
    IO.puts("KOGEN_TARGET_EVIDENCE_MANIFEST={probe}")
  end
end
''')
    parent = root / "boundary_test.exs"
    parent.write_text('''defmodule ShapingEvidenceBoundaryTest do
  use ExUnit.Case, async: false
  test "observes current successful child output boundary" do
    source = SOURCE
    {:ok, raw} = Kogen.IsolatedCase.run(source, "test emits evidence")
    assert raw =~ "KOGEN_TARGET_EVIDENCE_MANIFEST={probe}"
    forwarded = ExUnit.CaptureIO.capture_io(fn ->
      Kogen.IsolatedCase.run!(source, "test emits evidence")
    end)
    refute forwarded =~ "KOGEN_TARGET_EVIDENCE_MANIFEST"
    IO.puts("OBSERVED: run/3 captures marker; successful run!/3 discards marker")
  end
end
'''.replace("SOURCE", '"' + str(child) + '"'))
    result = subprocess.run(["mix", "test", str(parent)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="")
    raise SystemExit(result.returncode)
