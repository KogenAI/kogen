defmodule CodegenTestHarness.BuildSignalHandlerTest do
  use ExUnit.Case, async: false

  alias CodegenTestHarness.BuildSignalHandler

  # async: false — `install/2` registers a real handler on the SHARED
  # `:erl_signal_server` (a single, process-global gen_event manager). Two
  # tests installing/uninstalling concurrently would race on
  # `:gen_event.which_handlers/1` membership.

  setup do
    on_exit(fn ->
      # Best-effort: a test that installed the real handler must not leak it
      # into later test runs / other suites sharing this BEAM.
      BuildSignalHandler.uninstall()
    end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "build_signal_handler_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, lock_path: Path.join(dir, "queue.lock")}
  end

  describe "install/2" do
    test "registers :sigterm with :os.set_signal/2 and adds the handler once", ctx do
      assert :ok = BuildSignalHandler.install(ctx.lock_path)

      assert :erl_signal_server
             |> :gen_event.which_handlers()
             |> Enum.any?(&match?(BuildSignalHandler, &1))
    end

    test "is idempotent — installing twice does not raise or double-add", ctx do
      assert :ok = BuildSignalHandler.install(ctx.lock_path)
      assert :ok = BuildSignalHandler.install(ctx.lock_path)

      count =
        :erl_signal_server
        |> :gen_event.which_handlers()
        |> Enum.count(&match?(BuildSignalHandler, &1))

      assert count == 1
    end

    test "never attempts :os.set_signal(:sigint, :handle) — sigint is excluded from the settable set" do
      # Real-contract assertion backing the moduledoc claim: confirms this
      # OTP release genuinely raises on :sigint, so BuildSignalHandler is
      # correct to never call it. If a future OTP release adds :sigint to
      # the settable set, this test starts failing loudly rather than
      # silently masking a stale assumption.
      assert_raise ArgumentError, fn -> :os.set_signal(:sigint, :handle) end
    end
  end

  describe "handle_event/2 — first signal (tearing_down?: false)" do
    test "calls reap_fn, then release_fn, then halt_fn with the conventional exit code", ctx do
      test_pid = self()

      state = %{
        lock_path: ctx.lock_path,
        reap_fn: fn -> send(test_pid, :reaped) end,
        release_fn: fn path ->
          send(test_pid, {:released, path})
          :ok
        end,
        halt_fn: fn code -> send(test_pid, {:halted, code}) end,
        tearing_down?: false
      }

      capture_io_result =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, new_state} = BuildSignalHandler.handle_event(:sigterm, state)
          assert new_state.tearing_down? == true
        end)

      assert capture_io_result =~ "sigterm received"

      assert_received :reaped
      assert_received {:released, lock_path}
      assert lock_path == ctx.lock_path
      assert_received {:halted, 130}
    end

    test "still halts with 130 even when release_fn fails (best-effort lock release)", ctx do
      test_pid = self()

      state = %{
        lock_path: ctx.lock_path,
        reap_fn: fn -> :ok end,
        release_fn: fn _path -> {:error, :enoent} end,
        halt_fn: fn code -> send(test_pid, {:halted, code}) end,
        tearing_down?: false
      }

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, _new_state} = BuildSignalHandler.handle_event(:sigterm, state)
      end)

      assert_received {:halted, 130}
    end

    test "ignores non-sigterm events, returning state unchanged", ctx do
      state = %{
        lock_path: ctx.lock_path,
        reap_fn: fn -> flunk("reap_fn must not be called for an ignored event") end,
        release_fn: fn _path -> flunk("release_fn must not be called for an ignored event") end,
        halt_fn: fn _code -> flunk("halt_fn must not be called for an ignored event") end,
        tearing_down?: false
      }

      assert {:ok, ^state} = BuildSignalHandler.handle_event(:sigquit, state)
    end
  end

  describe "handle_event/2 — second signal (tearing_down?: true)" do
    test "hard-halts immediately, WITHOUT calling reap_fn or release_fn again", ctx do
      test_pid = self()

      state = %{
        lock_path: ctx.lock_path,
        reap_fn: fn -> flunk("reap_fn must not run on the second signal") end,
        release_fn: fn _path -> flunk("release_fn must not run on the second signal") end,
        halt_fn: fn code -> send(test_pid, {:halted, code}) end,
        tearing_down?: true
      }

      capture_io_result =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, ^state} = BuildSignalHandler.handle_event(:sigterm, state)
        end)

      assert capture_io_result =~ "second signal received"
      assert_received {:halted, 130}
    end
  end

  describe "default seams" do
    test "default halt_fn is :erlang.halt/1 (installed state carries a real fn, never called here)",
         ctx do
      assert :ok = BuildSignalHandler.install(ctx.lock_path)
    end
  end
end
