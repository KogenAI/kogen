defmodule Kogen.Ctx do
  @moduledoc "Builds the native kogen-ctx binary."
  use Boundary, deps: []

  def fetch(root, opts \\ []) do
    args =
      ["fetch", "--locked"] ++
        if(opts[:offline], do: ["--offline"], else: []) ++
        ["--manifest-path", Path.join(root, "native/kogen-ctx/Cargo.toml")]

    run_cargo(root, args)
  end

  def build(root) do
    args = [
      "build",
      "--release",
      "--locked",
      "--offline",
      "--manifest-path",
      Path.join(root, "native/kogen-ctx/Cargo.toml"),
      "--target-dir",
      Path.join(root, "_build/cargo")
    ]

    case run_cargo(root, args) do
      :ok -> {:ok, Path.join(root, "_build/cargo/release/kogen-ctx")}
      {:error, _} = e -> e
    end
  end

  defp run_cargo(root, args) do
    case System.cmd("cargo", args, cd: root, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "cargo exited #{status}: #{tail(out)}"}
    end
  rescue
    e in ErlangError ->
      if Exception.message(e) =~ "enoent" do
        {:error, "cargo not found on PATH: install Rust 1.97.1 (mise.toml pins it)"}
      else
        {:error, Exception.message(e)}
      end

    e ->
      {:error, Exception.message(e)}
  end

  defp tail(out) do
    out |> String.split("\n") |> Enum.take(-20) |> Enum.join("\n") |> String.trim()
  end
end
