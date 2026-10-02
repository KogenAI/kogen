defmodule Kogen.Testkit.GitTest do
  use Kogen.Testkit.Case

  test "creates a small committed repository under the testkit temporary root", %{
    tmp_dir: tmp_dir
  } do
    repo = Kogen.Testkit.Git.create!(tmp_dir)

    assert File.dir?(Path.join(repo, ".git"))
    assert File.read!(Path.join(repo, "README.md")) == "fixture\n"
  end
end
