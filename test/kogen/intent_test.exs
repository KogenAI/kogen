defmodule Kogen.IntentTest do
  use ExUnit.Case, async: true

  alias Kogen.Intent

  # -- helpers ---------------------------------------------------------

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-intent-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_yaml!(dir, relative_path, content) do
    full_path = Path.join(dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    full_path
  end

  @valid_config """
  harness: codex
  shaping:   {model: fable, effort: medium}
  developer: {model: sonnet, effort: high}
  reviewer:  {model: sonnet, effort: high}
  helpers:
    scout:  {model: scout, effort: low}
    worker: {model: worker, effort: medium}
    expert: {model: expert, effort: medium}
  outer_resumptions: 2
  """

  @valid_intent """
  id: 01a0711c-5df0-7822-925c-640efbec8e6c
  slug: sample-intent
  title: Sample intent
  may_change_guarded_paths:
    - lib/**
    - test/**
  """

  # -- read_config/1 ----------------------------------------------------

  describe "read_config/1" do
    test "parses the real tracked .kogen/config.yaml" do
      assert {:ok, config} = Intent.read_config()

      assert %{
               harness: harness,
               shaping: %{model: shaping_model, effort: shaping_effort},
               developer: %{model: developer_model, effort: developer_effort},
               reviewer: %{model: reviewer_model, effort: reviewer_effort},
               helpers: %{
                 scout: %{model: scout_model, effort: scout_effort},
                 worker: %{model: worker_model, effort: worker_effort},
                 expert: %{model: expert_model, effort: expert_effort}
               },
               outer_resumptions: outer_resumptions
             } = config

      assert is_binary(harness)
      assert is_binary(shaping_model)
      assert is_binary(shaping_effort)
      assert is_binary(developer_model)
      assert is_binary(developer_effort)
      assert is_binary(reviewer_model)
      assert is_binary(reviewer_effort)
      assert is_binary(scout_model)
      assert is_binary(scout_effort)
      assert is_binary(worker_model)
      assert is_binary(worker_effort)
      assert is_binary(expert_model)
      assert is_binary(expert_effort)
      assert is_integer(outer_resumptions)

      assert config.shaping == %{model: "gpt-6-astra", effort: "low"}
      assert config.developer == %{model: "gpt-5.6-sol", effort: "low"}
      assert config.reviewer == %{model: "gpt-5.6-terra", effort: "medium"}

      assert config.helpers == %{
               scout: %{model: "gpt-5.6-luna", effort: "low"},
               worker: %{model: "gpt-5.6-luna", effort: "medium"},
               expert: %{model: "gpt-5.6-sol", effort: "medium"}
             }
    end

    test "parses an explicit valid config path" do
      dir = tmp_dir!()
      path = write_yaml!(dir, "config.yaml", @valid_config)

      assert {:ok,
              %{
                harness: "codex",
                shaping: %{model: "fable", effort: "medium"},
                developer: %{model: "sonnet", effort: "high"},
                reviewer: %{model: "sonnet", effort: "high"},
                helpers: %{
                  scout: %{model: "scout", effort: "low"},
                  worker: %{model: "worker", effort: "medium"},
                  expert: %{model: "expert", effort: "medium"}
                },
                outer_resumptions: 2
              }} = Intent.read_config(path)
    end

    test "refuses to start when the file is missing" do
      dir = tmp_dir!()
      path = Path.join(dir, "does-not-exist.yaml")

      assert {:error, reason} = Intent.read_config(path)
      assert reason == "missing #{path}"
    end

    test "refuses to start when a top-level required key is absent" do
      dir = tmp_dir!()

      path =
        write_yaml!(dir, "config.yaml", """
        shaping:   {model: fable, effort: medium}
        developer: {model: sonnet, effort: high}
        reviewer:  {model: sonnet, effort: high}
        outer_resumptions: 2
        """)

      assert {:error, "config.yaml missing required key: harness"} = Intent.read_config(path)
    end

    test "refuses to start when a nested role key is absent" do
      dir = tmp_dir!()

      path =
        write_yaml!(dir, "config.yaml", """
        harness: codex
        shaping:   {model: fable}
        developer: {model: sonnet, effort: high}
        reviewer:  {model: sonnet, effort: high}
        helpers:
          scout:  {model: scout, effort: low}
          worker: {model: worker, effort: medium}
          expert: {model: expert, effort: medium}
        outer_resumptions: 2
        """)

      assert {:error, "config.yaml missing required key: shaping.effort"} =
               Intent.read_config(path)
    end

    test "refuses to start when required helper configuration is absent or incomplete" do
      dir = tmp_dir!()

      missing_helpers =
        write_yaml!(dir, "missing-helpers.yaml", """
        harness: codex
        shaping: {model: fable, effort: low}
        developer: {model: fable, effort: low}
        reviewer: {model: fable, effort: low}
        outer_resumptions: 2
        """)

      incomplete_helper =
        write_yaml!(dir, "incomplete-helper.yaml", """
        harness: codex
        shaping: {model: fable, effort: low}
        developer: {model: fable, effort: low}
        reviewer: {model: fable, effort: low}
        helpers:
          scout: {model: scout, effort: low}
          worker: {model: worker, effort: medium}
        outer_resumptions: 2
        """)

      assert {:error, "config.yaml missing required key: helpers"} =
               Intent.read_config(missing_helpers)

      assert {:error, "config.yaml missing required key: helpers.expert"} =
               Intent.read_config(incomplete_helper)
    end

    test "refuses missing, blank, and wrong-typed model and effort for every configured profile" do
      profiles = [
        "shaping",
        "developer",
        "reviewer",
        "helpers.scout",
        "helpers.worker",
        "helpers.expert"
      ]

      for profile <- profiles,
          field <- ["model", "effort"],
          kind <- [:missing, :blank, :wrong_type] do
        dir = tmp_dir!()
        path = write_yaml!(dir, "config.yaml", config_with_invalid_profile(profile, field, kind))
        expected = "config.yaml missing required key: #{profile}.#{field}"

        assert {:error, ^expected} = Intent.read_config(path)
      end
    end

    test "refuses to start when outer_resumptions is absent" do
      dir = tmp_dir!()

      path =
        write_yaml!(dir, "config.yaml", """
        harness: codex
        shaping:   {model: fable, effort: medium}
        developer: {model: sonnet, effort: high}
        reviewer:  {model: sonnet, effort: high}
        helpers:
          scout:  {model: scout, effort: low}
          worker: {model: worker, effort: medium}
          expert: {model: expert, effort: medium}
        """)

      assert {:error, "config.yaml missing required key: outer_resumptions"} =
               Intent.read_config(path)
    end

    test "refuses to start when outer_resumptions is not an integer" do
      dir = tmp_dir!()

      path =
        write_yaml!(dir, "config.yaml", """
        harness: codex
        shaping:   {model: fable, effort: medium}
        developer: {model: sonnet, effort: high}
        reviewer:  {model: sonnet, effort: high}
        helpers:
          scout:  {model: scout, effort: low}
          worker: {model: worker, effort: medium}
          expert: {model: expert, effort: medium}
        outer_resumptions: "two"
        """)

      assert {:error, "config.yaml missing required key: outer_resumptions"} =
               Intent.read_config(path)
    end
  end

  defp config_with_invalid_profile(profile, field, kind) do
    roles = ["shaping", "developer", "reviewer"]
    helpers = ["scout", "worker", "expert"]

    role_lines =
      Enum.map_join(roles, "\n", fn role ->
        "#{role}: #{profile_mapping(role, profile, field, kind)}"
      end)

    helper_lines =
      Enum.map_join(helpers, "\n", fn helper ->
        "  #{helper}: #{profile_mapping("helpers.#{helper}", profile, field, kind)}"
      end)

    """
    harness: codex
    #{role_lines}
    helpers:
    #{helper_lines}
    outer_resumptions: 2
    """
  end

  defp profile_mapping(current, profile, field, kind) do
    values = %{model: "model-#{current}", effort: "effort-#{current}"}

    values =
      if current == profile do
        Map.put(values, String.to_existing_atom(field), invalid_value(kind))
      else
        values
      end

    values
    |> Enum.reject(fn {_field, value} -> value == :missing end)
    |> Enum.map_join(", ", fn {name, value} -> "#{name}: #{yaml_value(value)}" end)
    |> then(&"{#{&1}}")
  end

  defp invalid_value(:missing), do: :missing
  defp invalid_value(:blank), do: ""
  defp invalid_value(:wrong_type), do: 42

  defp yaml_value(value) when is_binary(value), do: inspect(value)
  defp yaml_value(value), do: to_string(value)

  # -- read/2 ------------------------------------------------------------

  describe "read/2" do
    test "reads a valid intent.yaml" do
      base_dir = tmp_dir!()
      write_yaml!(base_dir, "sample-intent/intent.yaml", @valid_intent)

      assert {:ok,
              %{
                id: "01a0711c-5df0-7822-925c-640efbec8e6c",
                slug: "sample-intent",
                title: "Sample intent",
                may_change_guarded_paths: ["lib/**", "test/**"],
                raw: raw
              }} = Intent.read("sample-intent", base_dir)

      assert is_map(raw)
    end

    test "reads the same Intent identity from Approved and Complete directories" do
      fixture_root = tmp_dir!()
      approved = Path.join(fixture_root, "approved")
      complete = Path.join(fixture_root, "complete")
      write_yaml!(approved, "sample-intent/intent.yaml", @valid_intent)

      assert {:ok, approved_intent} = Intent.read("sample-intent", approved)
      File.mkdir_p!(complete)
      File.rename!(Path.join(approved, "sample-intent"), Path.join(complete, "sample-intent"))
      assert {:ok, ^approved_intent} = Intent.read("sample-intent", complete)
      refute File.exists?(Path.join(approved, "sample-intent"))
    end

    test "fails when intent.yaml is missing required key: id" do
      base_dir = tmp_dir!()

      write_yaml!(base_dir, "sample-intent/intent.yaml", """
      slug: sample-intent
      title: Sample intent
      may_change_guarded_paths:
        - lib/**
      """)

      assert {:error, "intent.yaml missing required key: id"} =
               Intent.read("sample-intent", base_dir)
    end

    test "fails when intent.yaml is missing required key: title" do
      base_dir = tmp_dir!()

      write_yaml!(base_dir, "sample-intent/intent.yaml", """
      id: 01a0711c-5df0-7822-925c-640efbec8e6c
      slug: sample-intent
      may_change_guarded_paths:
        - lib/**
      """)

      assert {:error, "intent.yaml missing required key: title"} =
               Intent.read("sample-intent", base_dir)
    end

    test "fails when intent.yaml is missing required key: may_change_guarded_paths" do
      base_dir = tmp_dir!()

      write_yaml!(base_dir, "sample-intent/intent.yaml", """
      id: 01a0711c-5df0-7822-925c-640efbec8e6c
      slug: sample-intent
      title: Sample intent
      """)

      assert {:error, "intent.yaml missing required key: may_change_guarded_paths"} =
               Intent.read("sample-intent", base_dir)
    end

    test "fails when may_change_guarded_paths is present but empty" do
      base_dir = tmp_dir!()

      write_yaml!(base_dir, "sample-intent/intent.yaml", """
      id: 01a0711c-5df0-7822-925c-640efbec8e6c
      slug: sample-intent
      title: Sample intent
      may_change_guarded_paths: []
      """)

      assert {:error, "intent.yaml missing required key: may_change_guarded_paths"} =
               Intent.read("sample-intent", base_dir)
    end

    test "fails when the intent.yaml file is absent entirely" do
      base_dir = tmp_dir!()
      expected_path = Path.join([base_dir, "ghost-intent", "intent.yaml"])

      assert {:error, reason} = Intent.read("ghost-intent", base_dir)
      assert reason == "intent.yaml missing: #{expected_path}"
    end
  end

  # -- mint_uuid7/0 --------------------------------------------------------

  describe "mint_uuid7/0" do
    @uuid_shape ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    test "mints RFC 9562-shaped, unique, monotonically-timestamped UUIDv7s" do
      uuids = for _ <- 1..1000, do: Intent.mint_uuid7()

      for uuid <- uuids do
        assert String.length(uuid) == 36
        assert uuid =~ @uuid_shape

        [_, _, third, fourth, _] = String.split(uuid, "-")
        assert String.first(third) == "7"
        assert String.first(fourth) in ~w(8 9 a b)
      end

      assert Enum.uniq(uuids) |> length() == 1000

      timestamps = Enum.map(uuids, &extract_timestamp/1)

      timestamps
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [earlier, later] ->
        assert later >= earlier
      end)
    end

    defp extract_timestamp(uuid) do
      [group1, group2 | _rest] = String.split(uuid, "-")
      String.to_integer(group1 <> group2, 16)
    end
  end
end
