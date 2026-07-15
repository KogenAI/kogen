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

  describe "Move 3 — tree=<os_pid> token" do
    test "acquire/4 writes tree=<os_pid> when :tree_os_pid opt is given", ctx do
      assert :ok =
               BuildLock.acquire(ctx.lock_path, "queue", fn _pid -> false end,
                 tree_os_pid: 54321
               )

      content = File.read!(ctx.lock_path)
      assert content == "#{System.pid()} queue tree=54321\n"
    end

    test "acquire/3 (no opts) omits the tree= token — pre-Move-3 format preserved", ctx do
      assert :ok = BuildLock.acquire(ctx.lock_path, "solo", fn _pid -> false end)
      content = File.read!(ctx.lock_path)
      assert content == "#{System.pid()} solo\n"
    end

    test "acquire/4 reclaims a dead-pid lock with NO tree= token (pre-Move-3 behavior unchanged)",
         ctx do
      File.write!(ctx.lock_path, "99999 solo\n")
      assert :ok = BuildLock.acquire(ctx.lock_path, "solo", fn _pid -> false end)
    end

    test "acquire/4 REFUSES when lock-holder pid is dead but its tree pid is alive", ctx do
      File.write!(ctx.lock_path, "99999 queue tree=#{System.pid()}\n")

      pid_alive_fn = fn
        "99999" -> false
        pid_str -> pid_str == System.pid()
      end

      assert {:error, reason} = BuildLock.acquire(ctx.lock_path, "queue", pid_alive_fn)
      assert reason =~ "dead but its build tree"
      assert reason =~ System.pid()
      assert reason =~ "kill -9 #{System.pid()}"
    end

    test "acquire/4 reclaims when BOTH lock-holder pid AND tree pid are dead", ctx do
      File.write!(ctx.lock_path, "99999 queue tree=99998\n")

      pid_alive_fn = fn _pid -> false end

      assert :ok = BuildLock.acquire(ctx.lock_path, "queue", pid_alive_fn, tree_os_pid: 11111)
      content = File.read!(ctx.lock_path)
      assert content == "#{System.pid()} queue tree=11111\n"
    end

    test "acquire/4 still refuses on a LIVE lock-holder pid regardless of tree pid", ctx do
      File.write!(ctx.lock_path, "12345 queue tree=99999\n")

      pid_alive_fn = fn
        "12345" -> true
        _ -> false
      end

      assert {:error, reason} = BuildLock.acquire(ctx.lock_path, "queue", pid_alive_fn)
      assert reason =~ "already running"
      assert reason =~ "12345"
    end
  end

  describe "update_tree_pid/2" do
    test "rewrites the tree= token, preserving pid + label", ctx do
      File.write!(ctx.lock_path, "42 queue tree=1\n")
      assert :ok = BuildLock.update_tree_pid(ctx.lock_path, 2)
      assert File.read!(ctx.lock_path) == "42 queue tree=2\n"
    end

    test "adds a tree= token to a lock file that never had one", ctx do
      File.write!(ctx.lock_path, "42 solo\n")
      assert :ok = BuildLock.update_tree_pid(ctx.lock_path, 777)
      assert File.read!(ctx.lock_path) == "42 solo tree=777\n"
    end

    test "is a no-op (never raises) when the lock file is absent", ctx do
      refute File.exists?(ctx.lock_path)
      assert :ok = BuildLock.update_tree_pid(ctx.lock_path, 777)
    end
  end
end
