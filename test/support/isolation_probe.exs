# This deliberately failing fixture is selected only by the isolation regression,
# never discovered as a standalone suite file.
# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
defmodule Kogen.IsolationProbe do
  use Kogen.IsolatedCase, async: true

  test "overlap" do
    root = System.fetch_env!("PROBE_ROOT")
    name = System.fetch_env!("PROBE_NAME")
    peer = System.fetch_env!("PROBE_PEER")
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.cd!(dir)
    System.put_env("PROBE_LOCAL", name)
    File.write!(Path.join(root, name <> ".started"), System.pid())
    File.write!(Path.join(root, name <> ".count"), "once\n", [:append])

    assert Enum.any?(1..200, fn _ ->
             if File.exists?(Path.join(root, peer <> ".started")) do
               true
             else
               Process.sleep(10)
               false
             end
           end),
           "independent children did not overlap"

    assert File.stat!(File.cwd!()).inode == File.stat!(dir).inode
    assert System.fetch_env!("PROBE_LOCAL") == name
    File.write!(Path.join(root, name <> ".tmp"), System.tmp_dir!())
  end

  test "assertion failure" do
    if marker = System.get_env("PROBE_PID") do
      Task.start(fn ->
        System.cmd("sh", [
          "-c",
          "echo $$ > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; exec sleep 60",
          "--",
          marker
        ])
      end)

      assert Enum.any?(1..100, fn _ ->
               if File.exists?(marker),
                 do: true,
                 else:
                   (
                     Process.sleep(10)
                     false
                   )
             end)
    end

    assert false, "intentional isolated assertion"
  end

  test "nonzero exit" do
    if marker = System.get_env("PROBE_PID") do
      Task.start(fn ->
        System.cmd("sh", [
          "-c",
          "echo $$ > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; exec sleep 60",
          "--",
          marker
        ])
      end)

      assert Enum.any?(1..100, fn _ ->
               Process.sleep(10)
               File.exists?(marker)
             end)
    end

    IO.puts("intentional isolated exit")
    System.halt(23)
  end

  test "timeout with child" do
    marker = System.fetch_env!("PROBE_PID")
    File.write!(marker <> ".root", System.tmp_dir!())

    System.cmd("sh", [
      "-c",
      "echo $$ > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; exec sleep 60",
      "--",
      marker
    ])
  end

  test "passing test with undeletable directory" do
    root = System.tmp_dir!()
    File.write!(System.fetch_env!("PROBE_ROOT_MARKER"), root)
    blocked = Path.join(root, "undeletable")
    File.mkdir!(blocked)
    File.write!(Path.join(blocked, "retained.txt"), "cleanup must report failure\n")
    File.chmod!(blocked, 0o500)
    assert File.regular?(Path.join(blocked, "retained.txt"))
  end
end
