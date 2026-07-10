defmodule CodegenTestHarness.BuildLockTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.BuildLock

  setup do
    dir = Path.join(System.tmp_dir!(), "build_lock_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, lock_path: Path.join(dir, "queue.lock")}
  end

  test "acquire/3 writes pid+label when no lock exists", ctx do
    assert :ok = BuildLock.acquire(ctx.lock_path, "solo", fn _pid -> false end)
    assert File.exists?(ctx.lock_path)
    content = File.read!(ctx.lock_path)
    assert content =~ "#{System.pid()} solo\n"
  end

  test "acquire/3 refuses when a live pid holds the lock", ctx do
    File.write!(ctx.lock_path, "12345 solo\n")

    assert {:error, reason} = BuildLock.acquire(ctx.lock_path, "solo", fn _pid -> true end)
    assert reason =~ "already running"
    assert reason =~ "12345"
  end

  test "acquire/3 reclaims a stale (dead-pid) lock", ctx do
    File.write!(ctx.lock_path, "99999 solo\n")

    assert :ok = BuildLock.acquire(ctx.lock_path, "solo", fn _pid -> false end)
    content = File.read!(ctx.lock_path)
    assert content =~ "#{System.pid()} solo\n"
  end

  test "acquire/3 creates parent dirs when missing", ctx do
    nested = Path.join([ctx.dir, "a", "b", "queue.lock"])
    assert :ok = BuildLock.acquire(nested, "solo", fn _pid -> false end)
    assert File.exists?(nested)
  end

  test "release/1 removes the lock file", ctx do
    File.write!(ctx.lock_path, "1 solo\n")
    assert :ok = BuildLock.release(ctx.lock_path)
    refute File.exists?(ctx.lock_path)
  end

  test "release/1 is a no-op when the lock file is absent", ctx do
    refute File.exists?(ctx.lock_path)
    assert :ok = BuildLock.release(ctx.lock_path)
  end

  test "default_pid_alive?/1 returns true for the current OS pid" do
    assert BuildLock.default_pid_alive?(System.pid())
  end

  test "default_pid_alive?/1 returns false for a non-numeric pid string" do
    refute BuildLock.default_pid_alive?("not-a-pid")
  end

  test "default_pid_alive?/1 returns false for a pid unlikely to be alive" do
    refute BuildLock.default_pid_alive?("999999")
  end
end
