defmodule Kogen.CtxBuildTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Kogen.Ctx.Build, as: CtxBuildTask

  test "D1 mix task prints only the executable path" do
    root = File.cwd!()

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        CtxBuildTask.run(["--offline"])
      end)

    path = String.trim_trailing(out, "\n")
    assert out == "#{root}/_build/cargo/release/kogen-ctx\n"
    assert path == Path.join(root, "_build/cargo/release/kogen-ctx")
    assert File.regular?(path)
    assert Bitwise.band(File.stat!(path).mode, 0o111) != 0
    refute File.exists?(Path.join(root, "native/kogen-ctx/target"))
    assert "/native/kogen-ctx/target/" in String.split(File.read!(".gitignore"), "\n")
    assert_raise Mix.Error, fn -> CtxBuildTask.run(["--bogus"]) end
  end

  test "D2 check places cargo stages in preparation" do
    script = """
    import importlib.util, json
    s = importlib.util.spec_from_file_location('o', 'scripts/check/offline.py')
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
    root = __import__('pathlib').Path('.')
    print(json.dumps({
      'stages': [list(x) for x in m.CARGO_STAGES],
      'names': [m._stage_name(x) for x in m.CARGO_STAGES],
      'plain': m.plan_phases(root, 'guard', None),
      'split': m.plan_phases(root, 'guard', '/tmp/build')
    }))
    """

    {out, 0} = System.cmd("python3", ["-B", "-c", script], stderr_to_stdout: true)
    result = Jason.decode!(out)

    assert result["stages"] == [
             ["cargo", "fmt", "--check", "--manifest-path", "native/kogen-ctx/Cargo.toml"],
             [
               "cargo",
               "build",
               "--release",
               "--locked",
               "--offline",
               "--manifest-path",
               "native/kogen-ctx/Cargo.toml",
               "--target-dir",
               "_build/cargo"
             ],
             [
               "cargo",
               "test",
               "--release",
               "--locked",
               "--offline",
               "--manifest-path",
               "native/kogen-ctx/Cargo.toml",
               "--target-dir",
               "_build/cargo"
             ]
           ]

    assert result["names"] == ["cargo-fmt", "cargo-build", "cargo-test"]

    for phases <- [result["plain"], result["split"]] do
      compile_i =
        Enum.find_index(phases, &(["mix", "compile", "--warnings-as-errors", "--force"] in &1))

      test_i =
        Enum.find_index(
          phases,
          &(["mix", "test", "--exclude", "live", "--warnings-as-errors", "--exclude", "test"] in &1)
        )

      assert compile_i < test_i
      prep = Enum.at(phases, compile_i)
      assert Enum.all?(result["stages"], &(&1 in prep))
    end
  end

  test "D3 Rust tests include all NIST vectors" do
    {out, 0} =
      System.cmd(
        "cargo",
        [
          "test",
          "--release",
          "--locked",
          "--offline",
          "--manifest-path",
          "native/kogen-ctx/Cargo.toml",
          "--target-dir",
          "_build/cargo"
        ],
        stderr_to_stdout: true
      )

    assert out =~ "test sha256::tests::nist_vectors ... ok"
    source = File.read!("native/kogen-ctx/src/sha256.rs")

    for digest <- [
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
          "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        ],
        do: assert(source =~ digest)
  end

  test "D4 dependency and lock are pinned" do
    {json, 0} =
      System.cmd("cargo", ["metadata", "--format-version", "1", "--locked", "--offline"],
        cd: "native/kogen-ctx",
        stderr_to_stdout: true
      )

    metadata = Jason.decode!(json)
    package = Enum.find(metadata["packages"], &(&1["name"] == "kogen-ctx"))

    assert Enum.sort(Enum.map(package["dependencies"], & &1["name"])) == [
             "rusqlite",
             "serde_json",
             "tree-sitter",
             "tree-sitter-elixir"
           ]

    rusqlite = Enum.find(package["dependencies"], &(&1["name"] == "rusqlite"))
    assert "bundled" in rusqlite["features"]
    assert Path.expand(metadata["target_directory"]) == Path.expand("_build/cargo")

    lock_hash =
      :crypto.hash(:sha256, File.read!("native/kogen-ctx/Cargo.lock"))
      |> Base.encode16(case: :lower)

    assert lock_hash == "2ef6860ee535431191646a3fd9fe9113d0c674b34b05d3cf2d8a306764fbf1a3"
  end

  test "D5 pins the toolchain" do
    {out, 0} = System.cmd("cargo", ["--version"])
    assert String.starts_with?(out, "cargo 1.97.1")
    mise = File.read!("mise.toml")
    assert mise =~ "python = \"3.14.7\""
    assert mise =~ "rust = \"1.97.1\""
  end

  test "D6 reports cargo failures" do
    assert {:error, "cargo exited " <> _} = Kogen.Ctx.build(System.tmp_dir!())
  end
end
