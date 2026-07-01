defmodule CodegenTestHarness.RoleResolverTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.RoleResolver

  @fixture_body """
  # Backend Developer

  Body line one.

  ---

  Body after a divider.
  """

  @fixture_md """
  ---
  name: developer-phoenix-backend
  model: sonnet
  effort: medium
  tools: Bash, Edit, Glob, Grep, MultiEdit, Read, WebFetch, Write
  ---

  #{@fixture_body}
  """

  @fixture_no_tools_md """
  ---
  name: developer-phoenix-backend
  model: sonnet
  effort: medium
  ---

  #{@fixture_body}
  """

  setup do
    base =
      Path.join(System.tmp_dir!(), "role_resolver_test_#{:erlang.unique_integer([:positive])}")

    agents_dir = Path.join(base, "agents")
    generated_dir = Path.join(base, "generated")
    File.mkdir_p!(agents_dir)
    File.mkdir_p!(generated_dir)

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, agents_dir: agents_dir, generated_dir: generated_dir}
  end

  describe "resolve_role/3 happy path" do
    test "claude: reads model/effort from real config.yaml, locates agent md, strips frontmatter",
         %{agents_dir: agents_dir, generated_dir: generated_dir} do
      File.write!(Path.join(agents_dir, "developer-phoenix-backend.md"), @fixture_md)

      {path, model, effort, tools} =
        RoleResolver.resolve_role("developer-phoenix-backend", "claude",
          agents_dir: agents_dir,
          generated_dir: generated_dir
        )

      assert model == "sonnet"
      assert effort == "medium"
      assert tools == "Bash, Edit, Glob, Grep, MultiEdit, Read, WebFetch, Write"

      body = File.read!(path)
      refute body =~ "tools:"
      assert body =~ "Body line one."
    end

    test "pi: reads pi-specific model/effort", %{
      agents_dir: agents_dir,
      generated_dir: generated_dir
    } do
      File.write!(Path.join(agents_dir, "developer-phoenix-backend.md"), @fixture_md)

      {_path, model, effort, _tools} =
        RoleResolver.resolve_role("developer-phoenix-backend", "pi",
          agents_dir: agents_dir,
          generated_dir: generated_dir
        )

      assert model == "openai-codex/gpt-5.4"
      assert effort == "medium"
    end
  end

  test "unknown role raises", %{agents_dir: agents_dir, generated_dir: generated_dir} do
    File.write!(Path.join(agents_dir, "no-such-role-xyz.md"), @fixture_md)

    assert_raise RuntimeError, fn ->
      RoleResolver.resolve_role("no-such-role-xyz", "claude",
        agents_dir: agents_dir,
        generated_dir: generated_dir
      )
    end
  end

  test "missing agent md raises", %{agents_dir: agents_dir, generated_dir: generated_dir} do
    assert_raise RuntimeError, fn ->
      RoleResolver.resolve_role("developer-phoenix-backend", "claude",
        agents_dir: agents_dir,
        generated_dir: generated_dir
      )
    end
  end

  test "falls back to generated_dir when agents_dir is missing the file", %{
    agents_dir: agents_dir,
    generated_dir: generated_dir
  } do
    generated_fixture = """
    ---
    name: developer-phoenix-backend
    model: sonnet
    effort: medium
    tools: Bash, Edit, Glob, Grep, MultiEdit, Read, WebFetch, Write
    ---

    # Generated fallback body.
    """

    File.write!(Path.join(generated_dir, "developer-phoenix-backend.md"), generated_fixture)

    {path, _model, _effort, _tools} =
      RoleResolver.resolve_role("developer-phoenix-backend", "claude",
        agents_dir: agents_dir,
        generated_dir: generated_dir
      )

    assert File.read!(path) =~ "Generated fallback body."
  end

  test "missing tools: line raises", %{agents_dir: agents_dir, generated_dir: generated_dir} do
    File.write!(Path.join(agents_dir, "developer-phoenix-backend.md"), @fixture_no_tools_md)

    assert_raise RuntimeError, fn ->
      RoleResolver.resolve_role("developer-phoenix-backend", "claude",
        agents_dir: agents_dir,
        generated_dir: generated_dir
      )
    end
  end

  test "strips only the leading frontmatter block, preserving a later --- divider", %{
    agents_dir: agents_dir,
    generated_dir: generated_dir
  } do
    File.write!(Path.join(agents_dir, "developer-phoenix-backend.md"), @fixture_md)

    {path, _model, _effort, _tools} =
      RoleResolver.resolve_role("developer-phoenix-backend", "claude",
        agents_dir: agents_dir,
        generated_dir: generated_dir
      )

    body = File.read!(path)
    refute body =~ "name: developer-phoenix-backend"
    assert body =~ "Body line one."
    assert body =~ "---"
    assert body =~ "Body after a divider."
  end
end
