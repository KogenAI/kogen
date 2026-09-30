defmodule Kogen.Codex.IsolationOracleTest do
  use ExUnit.Case, async: true

  alias Kogen.Codex.{AccountPlugins, Compatibility}

  # Excerpts of the retained compatibility-1790672559760-510 observation: the
  # helper listed the bundled 0.158.0 `.system` skills beside the project skill.
  @bundled ~w(imagegen openai-docs plugin-creator skill-creator skill-installer)
  @project "project-discovery-sentinel"
  @personal "personal-discovery-sentinel"

  @binding %{
    "version" => "0.158.0",
    "platform" => "darwin-arm64",
    "executable_sha256" => "788a818fbb9596869c7a487554507cb8bdca17584b8671112b23f9e225ba35c8",
    "system_tree_digest" => "9154c64a93823338efe718635ae6d711c011410790d2b61142929503db67faf2",
    "system_marker" => "8bcfb84cfbe4722a",
    "system_root" => "/h/.codex/skills/.system"
  }
  @origins Map.new(@bundled ++ [@project], fn name ->
             {name,
              if(name == @project, do: "/p/.agents/skills", else: "/h/.codex/skills/.system")}
           end)

  setup do
    {:ok, inventory} = Compatibility.load_bundled_inventory()
    {:ok, inventory: inventory}
  end

  defp surface(skills, extra \\ %{}),
    do:
      Map.merge(
        %{
          "skills" => skills,
          "source" => "test",
          "skill_origins" => Map.take(@origins, skills)
        },
        extra
      )

  defp observations(skills \\ @bundled ++ [@project]) do
    Map.new(~w(root helper resume interactive), &{&1, surface(skills)})
  end

  defp oracle(observations, inventory, binding \\ @binding) do
    Compatibility.isolation_oracle(observations,
      inventory: inventory,
      binding: binding,
      project_sentinel: @project,
      project_root: "/p/.agents/skills",
      forbidden: [@personal, "personal-fixture"]
    )
  end

  test "the retained bundled-names case classifies as bundled and passes", %{inventory: inventory} do
    result = oracle(observations(), inventory)
    assert result["status"] == "pass"
    assert result["reason"] == "all_names_classified"
    assert result["surfaces"]["helper"]["bundled"] == Enum.sort(@bundled)
    assert result["surfaces"]["helper"]["project"] == [@project]
    assert result["unclassified"] == []
  end

  test "a planted forbidden sentinel on any surface is a leak", %{inventory: inventory} do
    planted = put_in(observations(), ["resume", "skills"], @bundled ++ [@project, @personal])
    result = oracle(planted, inventory)
    assert result["status"] == "leak"
    assert result["forbidden"] == [@personal]

    for kind <- ["plugins", "mcp_servers"] do
      hostile = put_in(observations(), ["helper", kind], ["personal-fixture"])
      assert %{"status" => "leak"} = oracle(hostile, inventory)
    end

    raw = put_in(observations(), ["root", "forbidden_hits"], [@personal])
    assert %{"status" => "leak"} = oracle(raw, inventory)
  end

  test "an unknown name is unproven, named, and neither allowlisted nor leakage", %{
    inventory: inventory
  } do
    result = oracle(observations(@bundled ++ [@project, "mystery-skill"]), inventory)
    assert result["status"] == "unproven"
    assert result["reason"] == "unclassified_names"
    assert result["unclassified"] == ["mystery-skill"]
    assert result["forbidden"] == []

    # Unlisted plugin and MCP names are never bundled.
    plugin = put_in(observations(), ["helper", "plugins"], ["imagegen"])
    assert %{"status" => "unproven", "unclassified" => ["imagegen"]} = oracle(plugin, inventory)
  end

  test "an inventory bound to another version, digest or marker is unusable", %{
    inventory: inventory
  } do
    for {key, value, reason} <- [
          {"version", "0.200.0", "inventory_version_mismatch"},
          {"platform", "darwin-x64", "inventory_platform_mismatch"},
          {"executable_sha256", "0000", "inventory_runtime_digest_mismatch"},
          {"system_tree_digest", "0000", "inventory_tree_digest_mismatch"},
          {"system_marker", "other", "inventory_marker_mismatch"},
          {"system_tree_digest", nil, "system_tree_unobserved"},
          {"executable_sha256", nil, "runtime_digest_unobserved"}
        ] do
      result = oracle(observations(), inventory, Map.put(@binding, key, value))
      assert result["status"] == "unproven", key
      assert result["reason"] == reason, key
      assert result["inventory"]["usable"] == false
    end

    assert %{"status" => "unproven"} = oracle(observations(), nil)
  end

  test "a bundled name from a foreign root is foreign, not bundled", %{inventory: inventory} do
    foreign = put_in(observations(), ["helper", "skill_origins", "imagegen"], "/evil/skills")
    result = oracle(foreign, inventory)
    assert result["status"] == "fail"
    assert result["reason"] == "bundled_name_from_foreign_root"
    assert result["foreign"] == ["imagegen"]
    assert result["surfaces"]["helper"]["foreign"] == ["imagegen"]
    refute "imagegen" in result["surfaces"]["helper"]["bundled"]
    assert result["surfaces"]["root"]["foreign"] == []

    # A sibling directory sharing the pinned root as a prefix is still foreign.
    prefix =
      put_in(
        observations(),
        ["root", "skill_origins", "skill-creator"],
        "/h/.codex/skills/.system2"
      )

    assert %{"foreign" => ["skill-creator"]} = oracle(prefix, inventory)
  end

  test "a bundled name with no recorded origin cannot be proven bundled", %{inventory: inventory} do
    unknown = put_in(observations(), ["resume", "skill_origins"], %{})
    result = oracle(unknown, inventory)
    assert result["status"] == "unproven"
    assert result["unclassified"] == Enum.sort([@project | @bundled])
    assert result["surfaces"]["resume"]["bundled"] == []
  end

  test "a bundled name is not bundled when the pinned root is unknown", %{inventory: inventory} do
    result = oracle(observations(), inventory, Map.delete(@binding, "system_root"))
    assert result["status"] == "unproven"
    assert result["surfaces"]["root"]["bundled"] == []
  end

  test "a same-name skill from the personal root cannot stand in for the project skill", %{
    inventory: inventory
  } do
    personal = "/h/.agents/skills"
    swapped = put_in(observations(), ["helper", "skill_origins", @project], personal)
    result = oracle(swapped, inventory)
    assert result["status"] == "fail"
    assert result["surfaces"]["helper"]["project"] == []
    assert result["surfaces"]["helper"]["foreign"] == [@project]
    assert result["surfaces"]["root"]["project"] == [@project]
  end

  test "a foreign duplicate entry cannot hide behind a bundled or project one", %{
    inventory: inventory
  } do
    for {name, good} <- [
          {"imagegen", "/h/.codex/skills/.system"},
          {@project, "/p/.agents/skills"}
        ] do
      dup = put_in(observations(), ["helper", "skill_origins", name], [good, "/evil/skills"])
      result = oracle(dup, inventory)
      assert result["status"] == "fail", name
      assert result["reason"] == "bundled_name_from_foreign_root", name
      assert name in result["surfaces"]["helper"]["foreign"]
    end
  end

  test "duplicate catalog entries keep every origin when parsed" do
    text =
      "<skills_instructions>\n`r0` = `/h/.codex/skills/.system`\n`r1` = `/evil/skills`\n" <>
        "- imagegen: a (file: r0/imagegen/SKILL.md)\n- imagegen: b (file: r1/imagegen/SKILL.md)\n" <>
        "- skill-creator: c (file: r0/skill-creator/SKILL.md)\n</skills_instructions>"

    observation = Compatibility.parse_prompt_input(Jason.encode!(%{"input" => text}), [])

    assert observation["skill_origins"] == %{
             "imagegen" => ["/h/.codex/skills/.system", "/evil/skills"],
             "skill-creator" => "/h/.codex/skills/.system"
           }
  end

  test "a project sentinel with no recorded origin is unproven", %{inventory: inventory} do
    origins = Map.delete(@origins, @project)
    unknown = put_in(observations(), ["resume", "skill_origins"], Map.take(origins, @bundled))
    result = oracle(unknown, inventory)
    assert result["status"] == "unproven"
    assert result["reason"] == "unclassified_names"
    assert result["surfaces"]["resume"]["project"] == []
  end

  test "a missing project sentinel fails", %{inventory: inventory} do
    result = oracle(observations(@bundled), inventory)
    assert result["status"] == "fail"
    assert result["reason"] == "project_sentinel_missing"
  end

  test "a free-text absence claim without structured observation is unproven", %{
    inventory: inventory
  } do
    claimed =
      Map.put(observations(), "helper", %{
        "text" => "PERSONAL_CONTEXT_ABSENT",
        "source" => "free-text"
      })

    result = oracle(claimed, inventory)
    assert result["status"] == "unproven"
    assert result["reason"] == "no_structured_observation"
    assert result["surfaces"]["helper"]["observed"] == false

    assert %{"status" => "unproven"} = oracle(%{}, inventory)
    assert %{"status" => "unproven"} = oracle(nil, inventory)
  end

  test "prompt-input parsing yields catalog names, the .system root and raw sentinel hits" do
    catalog =
      "<skills_instructions>\n### Skill roots\n- `r0` = `/h/.codex/skills/.system`\n- `r1` = `/p/.agents/skills`\n### Available skills\n" <>
        "- imagegen: Generate images. (file: r0/imagegen/SKILL.md)\n" <>
        "- skill-creator: Create skills. (file: r0/skill-creator/SKILL.md)\n" <>
        "- #{@project}: x (file: r1/p/SKILL.md)\n</skills_instructions>"

    output = Jason.encode!([%{"content" => [%{"text" => catalog}]}])
    observation = Compatibility.parse_prompt_input(output, [@personal])

    assert observation["skills"] == ["imagegen", "skill-creator", @project]
    assert observation["system_root"] == "/h/.codex/skills/.system"

    assert observation["skill_origins"] == %{
             "imagegen" => "/h/.codex/skills/.system",
             "skill-creator" => "/h/.codex/skills/.system",
             @project => "/p/.agents/skills"
           }

    assert observation["forbidden_hits"] == []

    leaked = Compatibility.parse_prompt_input(output <> @personal, [@personal])
    assert leaked == nil or leaked["forbidden_hits"] == [@personal]

    with_hit =
      Compatibility.parse_prompt_input(
        Jason.encode!([%{"text" => catalog <> "\n" <> @personal}]),
        [@personal]
      )

    assert with_hit["forbidden_hits"] == [@personal]
    assert Compatibility.parse_prompt_input("not json", [@personal]) == nil
    assert Compatibility.parse_prompt_input("[]", [@personal]) == nil
  end

  test "tree digest is content-bound and ignores the marker" do
    dir = Path.join(System.tmp_dir!(), "oracle-tree-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(Path.join(dir, "a"))
    File.write!(Path.join(dir, "a/SKILL.md"), "one")
    File.write!(Path.join(dir, ".codex-system-skills.marker"), "m1")

    {:ok, first} = Compatibility.system_tree_digest(dir)
    File.write!(Path.join(dir, ".codex-system-skills.marker"), "m2")
    assert {:ok, ^first} = Compatibility.system_tree_digest(dir)

    File.write!(Path.join(dir, "a/SKILL.md"), "two")
    assert {:ok, changed} = Compatibility.system_tree_digest(dir)
    assert changed != first
    assert {:error, :system_tree_missing} = Compatibility.system_tree_digest(dir <> "-none")
  end

  test "bundled skill classification never yields an account plugin verdict" do
    refute function_exported?(Compatibility, :account_plugin_exclusion, 1)

    assert %{"status" => "unproven"} =
             AccountPlugins.evaluate([], runtime: "0.158.0", executable_sha256: "x")
  end
end
