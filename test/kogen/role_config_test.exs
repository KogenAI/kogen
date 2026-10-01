defmodule Kogen.RoleConfigTest do
  use ExUnit.Case, async: true

  alias Kogen.RoleConfig

  test "resolves project-local profiles with exact prompt bytes and hashes" do
    engine = engine_root()
    first = project_root()
    second = project_root()

    config =
      config_text("medium", "project:prompts/review#draft.md")
      |> String.replace(
        "prompt: project:prompts/review#draft.md",
        "prompt: \"project:prompts/review#draft.md\""
      )

    write_config!(first, config)
    File.mkdir_p!(Path.join(first, "prompts"))
    File.write!(Path.join(first, "prompts/review#draft.md"), "Project reviewer bytes\n")
    write_config!(second, config_text("medium", "reviewer"))

    assert {:ok, first_frozen} = RoleConfig.resolve(first, engine, "alternate")
    assert {:ok, second_frozen} = RoleConfig.resolve(second, engine)
    assert :ok = RoleConfig.validate_frozen(first_frozen)
    assert {:ok, shaping} = RoleConfig.role(first_frozen, "shaping")
    assert shaping["model"] == "gpt-6-luna"
    assert shaping["effort"] == "high"
    assert {:ok, reviewer} = RoleConfig.role(first_frozen, :reviewer)
    assert reviewer["prompt"]["identity"] == "project:prompts/review#draft.md"
    assert reviewer["prompt"]["bytes"] == "Project reviewer bytes\n"

    assert reviewer["prompt"]["sha256"] ==
             :crypto.hash(:sha256, "Project reviewer bytes\n") |> Base.encode16(case: :lower)

    assert first_frozen["project_identity"] != second_frozen["project_identity"]
    assert first_frozen["effective_fingerprint"] != second_frozen["effective_fingerprint"]
    assert {:ok, _json} = Jason.encode(first_frozen)
  end

  test "a frozen map survives later config and prompt edits" do
    engine = engine_root()
    project = project_root()
    write_config!(project, config_text("medium", "project:prompts/reviewer.md"))
    File.mkdir_p!(Path.join(project, "prompts"))
    prompt_path = Path.join(project, "prompts/reviewer.md")
    File.write!(prompt_path, "Original review prompt\n")

    assert {:ok, frozen} = RoleConfig.resolve(project, engine)
    frozen_fingerprint = frozen["effective_fingerprint"]
    write_config!(project, config_text("high", "reviewer"))
    File.write!(prompt_path, "Changed prompt\n")

    assert :ok = RoleConfig.validate_frozen(frozen)
    assert {:ok, reviewer} = RoleConfig.role(frozen, :reviewer)
    assert reviewer["prompt"]["bytes"] == "Original review prompt\n"
    assert frozen["effective_fingerprint"] == frozen_fingerprint
  end

  test "tampered frozen bytes, prompt digest, and fingerprint are rejected" do
    assert {:ok, frozen} = RoleConfig.resolve(project_root(), engine_root())
    prompt = get_in(frozen, ["roles", "reviewer", "prompt"])

    tampered_prompt =
      put_in(frozen, ["roles", "reviewer", "prompt", "bytes"], prompt["bytes"] <> "changed")

    tampered_hash =
      put_in(frozen, ["roles", "reviewer", "prompt", "sha256"], String.duplicate("0", 64))

    tampered_fingerprint = Map.put(frozen, "effective_fingerprint", String.duplicate("0", 64))

    tampered_config_hash =
      Map.put(frozen, "configuration_raw_sha256", String.duplicate("1", 64))

    assert {:error, _} = RoleConfig.validate_frozen(tampered_prompt)
    assert {:error, _} = RoleConfig.validate_frozen(tampered_hash)
    assert {:error, _} = RoleConfig.validate_frozen(tampered_fingerprint)
    assert {:error, _} = RoleConfig.validate_frozen(tampered_config_hash)
  end

  test "rejects unsupported settings, unknown policy keys, secrets, malformed YAML, and symlink prompts" do
    engine = engine_root()
    project = project_root()

    write_config!(project, config_text("medium", "reviewer", "max"))
    assert {:error, _} = RoleConfig.resolve(project, engine)

    quoted_duplicate =
      config_text("medium", "reviewer")
      |> String.replace(
        "      effort: high\n      prompt: reviewer",
        "      effort: high\n      \"effort\": max\n      prompt: reviewer"
      )

    assert {:ok, parsed_quoted} = YamlElixir.read_from_string(quoted_duplicate)
    assert get_in(parsed_quoted, ["configurations", "default", "reviewer", "effort"]) == "high"
    write_config!(project, quoted_duplicate)
    assert {:error, _} = RoleConfig.resolve(project, engine)

    escaped_key_duplicate = config_text("medium", "reviewer") <> "\"runt\\u0069me\": legacy\n"
    assert {:ok, parsed_escaped_key} = YamlElixir.read_from_string(escaped_key_duplicate)
    assert parsed_escaped_key["runtime"] == "custom"
    write_config!(project, escaped_key_duplicate)
    assert {:error, _} = RoleConfig.resolve(project, engine)

    spaced_key_duplicate = config_text("medium", "reviewer") <> "runtime : legacy\n"
    assert {:ok, parsed_spaced_key} = YamlElixir.read_from_string(spaced_key_duplicate)
    assert parsed_spaced_key["runtime"] == "custom"
    write_config!(project, spaced_key_duplicate)
    assert {:error, _} = RoleConfig.resolve(project, engine)

    flow_duplicate =
      config_text("medium", "reviewer")
      |> String.replace(
        "    reviewer:\n      model: gpt-6.1-sol\n      effort: high\n      prompt: reviewer\n      tools: [read, bash]\n      context: full\n",
        "    reviewer: {model: gpt-6.1-sol, effort: high, \"effort\": max, prompt: reviewer, tools: [read, bash], context: full}\n"
      )

    assert {:ok, parsed_flow} = YamlElixir.read_from_string(flow_duplicate)
    assert get_in(parsed_flow, ["configurations", "default", "reviewer", "effort"]) == "high"
    write_config!(project, flow_duplicate)
    assert {:error, _} = RoleConfig.resolve(project, engine)

    unsupported_provider =
      String.replace(config_text("medium", "reviewer"), "gpt-6-luna", "grok-4.7")

    write_config!(project, unsupported_provider)
    assert {:error, _} = RoleConfig.resolve(project, engine)

    write_config!(project, config_text("max", "reviewer"))
    assert {:error, _} = RoleConfig.resolve(project, engine)

    write_config!(project, config_text("medium", "reviewer") <> "disable_approval: true\n")
    assert {:error, _} = RoleConfig.resolve(project, engine)

    write_config!(
      project,
      config_text("medium", "reviewer") <> "# api_key: sk-12345678901234567890\n"
    )

    assert {:error, _} = RoleConfig.resolve(project, engine)

    write_config!(project, "runtime: [not-valid\n")
    assert {:error, _} = RoleConfig.resolve(project, engine)

    write_config!(project, config_text("medium", "reviewer") <> "runtime: custom\n")
    assert {:error, _} = RoleConfig.resolve(project, engine)

    File.mkdir_p!(Path.join(project, "prompts"))
    outside = Path.join(project_root(), "outside.md")
    File.write!(outside, "outside prompt")
    File.ln_s!(outside, Path.join(project, "prompts/reviewer.md"))
    write_config!(project, config_text("medium", "project:prompts/reviewer.md"))
    assert {:error, _} = RoleConfig.resolve(project, engine)
  end

  defp engine_root do
    Path.expand("../..", __DIR__)
  end

  defp project_root do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    root = Path.join(System.tmp_dir!(), "kogen-role-config-#{suffix}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp write_config!(project, text) do
    path = Path.join(project, ".kogen/config.yaml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp config_text(shaping_effort, reviewer_prompt_identity),
    do: config_text(shaping_effort, reviewer_prompt_identity, "high")

  defp config_text(shaping_effort, reviewer_prompt_identity, reviewer_effort) do
    roles = [
      {"shaping", "gpt-6-luna", shaping_effort, "shaping", "[read, write, edit, bash]"},
      {"developer", "gpt-6-luna", "medium", "developer", "[read, write, edit, bash]"},
      {"reviewer", "gpt-6.1-sol", reviewer_effort, reviewer_prompt_identity, "[read, bash]"},
      {"auditor", "gpt-6.1-sol", "high", "auditor", "[read, bash]"},
      {"expert", "gpt-6.1-sol", "high", "expert", "[read, bash]"}
    ]

    profile =
      Enum.map_join(roles, "", fn {role, model, effort, prompt, tools} ->
        "    #{role}:\n" <>
          "      model: #{model}\n" <>
          "      effort: #{effort}\n" <>
          "      prompt: #{prompt}\n" <>
          "      tools: #{tools}\n" <>
          "      context: full\n"
      end)

    "runtime: custom\n" <>
      "default_configuration: default\n" <>
      "configurations:\n" <>
      "  default:\n" <>
      profile <>
      "  alternate:\n" <>
      String.replace(profile, "      effort: medium\n", "      effort: high\n", global: false)
  end
end
