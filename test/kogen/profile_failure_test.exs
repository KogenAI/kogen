defmodule Kogen.ProfileFailureTest do
  use Kogen.IsolatedCase, async: true

  test "Reviewer preserves provider failures and only completed invalid verdicts are malformed" do
    dir =
      Path.join(System.tmp_dir!(), "kogen-profile-failure-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    executable = Path.join(dir, "provider")
    invocations = Path.join(dir, "invocations")

    original =
      Map.new(["KOGEN_HARNESS", "PROFILE_FAILURE_MODE", "PROFILE_FAILURE_INVOCATIONS"], fn key ->
        {key, System.get_env(key)}
      end)

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    File.write!(executable, """
    #!/bin/sh
    set -eu
    printf x >> "$PROFILE_FAILURE_INVOCATIONS"
    cat >/dev/null
    out= prev=
    for arg in "$@"; do [ "$prev" = --output-last-message ] && out="$arg"; prev="$arg"; done
    case "$PROFILE_FAILURE_MODE" in
      nonzero)
        printf '%s\\n' 'requested profile rejected by provider'
        exit 17
        ;;
      provider_error)
        printf '%s\\n' '{"type":"error","message":"requested profile unavailable"}'
        ;;
      incomplete)
        printf '%s\\n' '{"type":"thread.started","thread_id":"review"}'
        ;;
      malformed)
        printf '%s\\n' '{"not":"a verdict"}' > "$out"
        printf '%s\\n' '{"type":"thread.started","thread_id":"review"}' '{"type":"turn.completed","thread_id":"review"}'
        ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("PROFILE_FAILURE_INVOCATIONS", invocations)

    assert_failure!(invocations, "nonzero", fn ->
      assert {:error, {:provider_exit, 17, diagnostic}} =
               Kogen.Harness.launch_reviewer("review", "unavailable-profile", "low")

      assert diagnostic =~ "requested profile rejected by provider"
    end)

    assert_failure!(invocations, "provider_error", fn ->
      assert {:error,
              {:provider_error,
               %{"type" => "error", "message" => "requested profile unavailable"}}} =
               Kogen.Harness.launch_reviewer("review", "unavailable-profile", "low")
    end)

    assert_failure!(invocations, "incomplete", fn ->
      assert {:error, {:no_result_event, 0, diagnostic}} =
               Kogen.Harness.launch_reviewer("review", "unavailable-profile", "low")

      assert diagnostic =~ "thread.started"
    end)

    assert_failure!(invocations, "malformed", fn ->
      assert {:error, {:malformed_verdict, 0, details}} =
               Kogen.Harness.launch_reviewer("review", "unavailable-profile", "low")

      assert details["reviewer_session_id"] == "review"
      assert details["message"] == "{\"not\":\"a verdict\"}\n"
    end)
  end

  defp assert_failure!(invocations, mode, assertion) do
    File.rm_rf!(invocations)
    System.put_env("PROFILE_FAILURE_MODE", mode)
    assertion.()
    assert File.read!(invocations) == "x"
  end
end
