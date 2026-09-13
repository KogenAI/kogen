if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
  defmodule Kogen.IsolatedTargetEvidenceProbe do
    use ExUnit.Case, async: true

    test "emits progress, malformed and duplicate target frames, then bulk output" do
      IO.write("progress without a newline")
      IO.write("junkKOGEN_TARGET_EVIDENCE_MANIFEST\t{malformed}\n")
      IO.write("KOGEN_TARGET_EVIDENCE_MANIFEST\tfirst\n")
      IO.write("KOGEN_TARGET_EVIDENCE_MANIFEST\tfirst\n")
      IO.write(String.duplicate("bulk output ", 500))
    end

    test "does not emit target evidence" do
      IO.write("ordinary child output\n")
    end

    test "emits evidence and then fails" do
      IO.write("KOGEN_TARGET_EVIDENCE_MANIFEST\tfailure-frame\n")
      assert false, "child failure after evidence"
    end
  end
end

defmodule Kogen.IsolatedTargetEvidenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @probe __ENV__.file

  test "forwards every complete frame and suppresses unrelated captured output" do
    forwarded =
      capture_io(fn ->
        assert :ok =
                 Kogen.IsolatedCase.run!(
                   @probe,
                   5
                 )
      end)

    assert forwarded ==
             "KOGEN_TARGET_EVIDENCE_MANIFEST\t{malformed}\n" <>
               "KOGEN_TARGET_EVIDENCE_MANIFEST\tfirst\n" <>
               "KOGEN_TARGET_EVIDENCE_MANIFEST\tfirst\n"
  end

  test "required evidence rejects a successful child without a frame" do
    assert_raise ExUnit.AssertionError, ~r/no target evidence manifest/, fn ->
      Kogen.IsolatedCase.run!(@probe, 13, target_evidence: :required)
    end
  end

  test "child failure remains the result even when a frame was forwarded" do
    {error, forwarded} =
      with_capture(fn ->
        Kogen.IsolatedCase.run!(@probe, 17)
      end)

    assert %ExUnit.AssertionError{message: message} = error
    assert message =~ "child failure after evidence"
    assert forwarded == "KOGEN_TARGET_EVIDENCE_MANIFEST\tfailure-frame\n"
  end

  defp with_capture(fun) do
    parent = self()

    output =
      capture_io(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, error}
          end

        send(parent, {:isolated_target_evidence_result, result})
      end)

    receive do
      {:isolated_target_evidence_result, {:error, error}} -> {error, output}
    after
      1_000 -> flunk("did not receive isolated result")
    end
  end
end
