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

  @valid_route """
  harness: codex
  shaping:   {model: fable, effort: medium}
  developer: {model: sonnet, effort: high}
  reviewer:  {model: sonnet, effort: high}
  helpers:
    scout:  {model: scout, effort: low}
    worker: {model: worker, effort: medium}
    expert: {model: expert, effort: medium}
  """

  @other_route """
  harness: codex
  shaping:   {model: other-shaper, effort: low}
  developer: {model: other-developer, effort: medium}
  reviewer:  {model: other-reviewer, effort: high}
  helpers:
    scout:  {model: other-scout, effort: low}
    worker: {model: other-worker, effort: low}
    expert: {model: other-expert, effort: high}
  """

  # A routes config: `routes` is an ordered list of {name, route body}.
  defp routes_config(routes, options \\ []) do
    default = Keyword.get(options, :default_route, routes |> hd() |> elem(0))

    route_lines =
      Enum.map_join(routes, fn {name, body} ->
        "  #{name}:\n" <> indent(body, "    ")
      end)

    default_line = if default, do: "default_route: #{default}\n", else: ""

    default_line <>
      "routes:\n" <>
      route_lines <>
      Keyword.get(options, :tail, "outer_resumptions: 2\nverification_retries: 2\n")
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map_join(&(prefix <> &1 <> "\n"))
  end

  @valid_config """
  default_route: codex
  routes:
    codex:
      harness: codex
      shaping:   {model: fable, effort: medium}
      developer: {model: sonnet, effort: high}
      reviewer:  {model: sonnet, effort: high}
      helpers:
        scout:  {model: scout, effort: low}
        worker: {model: worker, effort: medium}
        expert: {model: expert, effort: medium}
  outer_resumptions: 2
  verification_retries: 2
  """

  @flat_config_error "config.yaml uses the replaced flat configuration shape (top-level harness and roles); define default_route and routes instead"

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
               outer_resumptions: outer_resumptions,
               verification_retries: verification_retries
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
      assert is_integer(verification_retries)
      assert verification_retries == 2

      assert config.route == "claude"
      assert config.harness == "claude"
      assert config.shaping == %{model: "claude-opus-5-5", effort: "medium"}
      assert config.developer == %{model: "claude-opus-5-5", effort: "medium"}
      assert config.reviewer == %{model: "claude-opus-5-5", effort: "medium"}

      assert config.helpers == %{
               scout: %{model: "claude-sonnet-5", effort: "low"},
               worker: %{model: "claude-sonnet-5", effort: "medium"},
               expert: %{model: "claude-opus-5-5", effort: "high"}
             }

      assert {:ok, codex} = Intent.read_config(".kogen/config.yaml", "codex")

      assert codex == %{
               route: "codex",
               harness: "codex",
               shaping: %{model: "gpt-5.6-sol", effort: "low"},
               developer: %{model: "gpt-5.6-sol", effort: "low"},
               reviewer: %{model: "gpt-5.6-terra", effort: "medium"},
               helpers: %{
                 scout: %{model: "gpt-5.6-luna", effort: "low"},
                 worker: %{model: "gpt-5.6-luna", effort: "medium"},
                 expert: %{model: "gpt-5.6-sol", effort: "medium"}
               },
               outer_resumptions: 2,
               verification_retries: 2
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
                outer_resumptions: 2,
                verification_retries: 2
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
        write_yaml!(
          dir,
          "config.yaml",
          routes_config([{"codex", @valid_route}], default_route: nil)
        )

      assert {:error, "config.yaml missing required key: default_route"} =
               Intent.read_config(path)

      path =
        write_yaml!(dir, "no-routes.yaml", """
        default_route: codex
        outer_resumptions: 2
        verification_retries: 2
        """)

      assert {:error, "config.yaml missing required key: routes"} = Intent.read_config(path)
    end

    test "refuses to start when a nested role key is absent" do
      dir = tmp_dir!()
      route = String.replace(@valid_route, "{model: fable, effort: medium}", "{model: fable}")
      path = write_yaml!(dir, "config.yaml", routes_config([{"codex", route}]))

      assert {:error, "config.yaml missing required key: routes.codex.shaping.effort"} =
               Intent.read_config(path)
    end

    test "refuses to start when required helper configuration is absent or incomplete" do
      dir = tmp_dir!()
      [roles, _helpers] = String.split(@valid_route, "helpers:\n")

      missing_helpers =
        write_yaml!(dir, "missing-helpers.yaml", routes_config([{"codex", roles}]))

      incomplete_helper =
        write_yaml!(
          dir,
          "incomplete-helper.yaml",
          routes_config([
            {"codex", String.replace(@valid_route, "expert: {model: expert, effort: medium}", "")}
          ])
        )

      assert {:error, "config.yaml missing required key: routes.codex.helpers"} =
               Intent.read_config(missing_helpers)

      assert {:error, "config.yaml missing required key: routes.codex.helpers.expert"} =
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
        expected = "config.yaml missing required key: routes.codex.#{profile}.#{field}"

        assert {:error, ^expected} = Intent.read_config(path)
      end
    end

    test "refuses to start when outer_resumptions is absent" do
      dir = tmp_dir!()

      path =
        write_yaml!(
          dir,
          "config.yaml",
          routes_config([{"codex", @valid_route}], tail: "verification_retries: 2\n")
        )

      assert {:error, "config.yaml missing required key: outer_resumptions"} =
               Intent.read_config(path)
    end

    test "refuses to start when outer_resumptions is not an integer" do
      dir = tmp_dir!()

      path =
        write_yaml!(
          dir,
          "config.yaml",
          routes_config([{"codex", @valid_route}],
            tail: "outer_resumptions: \"two\"\nverification_retries: 2\n"
          )
        )

      assert {:error, "config.yaml missing required key: outer_resumptions"} =
               Intent.read_config(path)
    end

    test "refuses to start when verification_retries is absent" do
      dir = tmp_dir!()
      path = String.replace(@valid_config, "verification_retries: 2", "")
      path = write_yaml!(dir, "config.yaml", path)

      assert {:error, "config.yaml missing required key: verification_retries"} =
               Intent.read_config(path)
    end

    test "refuses negative and noninteger verification_retries" do
      for value <- ["-1", "two", "1.5"] do
        dir = tmp_dir!()

        yaml =
          String.replace(
            @valid_config,
            "verification_retries: 2",
            "verification_retries: #{value}"
          )

        path = write_yaml!(dir, "config.yaml", yaml)

        assert {:error, "config.yaml missing required key: verification_retries"} =
                 Intent.read_config(path)
      end
    end

    test "accepts zero and two verification retries" do
      for retries <- [0, 2] do
        dir = tmp_dir!()

        yaml =
          String.replace(
            @valid_config,
            "verification_retries: 2",
            "verification_retries: #{retries}"
          )

        path = write_yaml!(dir, "config.yaml", yaml)

        assert {:ok, config} = Intent.read_config(path)
        assert config.verification_retries == retries
      end
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

    routes_config([{"codex", "harness: codex\n#{role_lines}\nhelpers:\n#{helper_lines}\n"}])
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

  describe "harness selection and proven Claude Code models" do
    @claude_route """
    harness: claude
    shaping:   {model: claude-opus-5-5, effort: medium}
    developer: {model: claude-opus-5-5, effort: medium}
    reviewer:  {model: claude-opus-5-5, effort: medium}
    helpers:
      scout:  {model: claude-sonnet-5, effort: low}
      worker: {model: claude-sonnet-5, effort: medium}
      expert: {model: claude-opus-5-5, effort: high}
    """

    @claude_config """
    default_route: claude
    routes:
      claude:
        harness: claude
        shaping:   {model: claude-opus-5-5, effort: medium}
        developer: {model: claude-opus-5-5, effort: medium}
        reviewer:  {model: claude-opus-5-5, effort: medium}
        helpers:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
          expert: {model: claude-opus-5-5, effort: high}
    outer_resumptions: 2
    verification_retries: 2
    """

    test "codex and claude are both supported harness names" do
      dir = tmp_dir!()

      assert {:ok, %{harness: "codex"}} =
               Intent.read_config(write_yaml!(dir, "c.yaml", @valid_config))

      assert {:ok, %{harness: "claude", developer: %{model: "claude-opus-5-5"}}} =
               Intent.read_config(write_yaml!(dir, "cc.yaml", @claude_config))
    end

    test "any other harness is rejected with the supported list" do
      dir = tmp_dir!()

      path =
        write_yaml!(
          dir,
          "c.yaml",
          String.replace(@valid_config, "harness: codex", "harness: gemini")
        )

      assert {:error, "unsupported harness: gemini; expected codex or claude"} =
               Intent.read_config(path)
    end

    test "a Claude Code role or helper model outside the proven list is refused with the list" do
      dir = tmp_dir!()

      for {from, to, label} <- [
            {"developer: {model: claude-opus-5-5", "developer: {model: claude-haiku-4-5-20251001",
             "developer"},
            {"scout:  {model: claude-sonnet-5", "scout:  {model: gpt-5.6-luna", "helpers.scout"}
          ] do
        path = write_yaml!(dir, "#{label}.yaml", String.replace(@claude_config, from, to))
        assert {:error, reason} = Intent.read_config(path)
        assert reason =~ "unsupported Claude Code model for #{label}"
        assert reason =~ "proven models: claude-opus-5-5, claude-sonnet-5"
      end
    end

    test "a Claude Code effort outside the proven efforts of its model is refused" do
      dir = tmp_dir!()

      config =
        String.replace(
          @claude_config,
          "reviewer:  {model: claude-opus-5-5, effort: medium}",
          "reviewer:  {model: claude-opus-5-5, effort: max}"
        )

      assert {:error, reason} = Intent.read_config(write_yaml!(dir, "effort.yaml", config))
      assert reason =~ "unsupported Claude Code effort for reviewer: claude-opus-5-5 at max"
    end

    test "Codex model routing is unchanged by the Claude Code picker" do
      dir = tmp_dir!()

      assert {:ok, %{developer: %{model: "sonnet"}}} =
               Intent.read_config(write_yaml!(dir, "c.yaml", @valid_config))
    end
  end

  describe "named routes" do
    test "no requested route resolves default_route and each name resolves only its own route" do
      dir = tmp_dir!()

      path =
        write_yaml!(
          dir,
          "config.yaml",
          routes_config(
            [{"codex", @valid_route}, {"other", @other_route}, {"claude", @claude_route}],
            default_route: "other",
            tail: "outer_resumptions: 1\nverification_retries: 0\n"
          )
        )

      assert {:ok, default} = Intent.read_config(path)
      assert {:ok, other} = Intent.read_config(path, "other")
      assert default == other

      assert other == %{
               route: "other",
               harness: "codex",
               shaping: %{model: "other-shaper", effort: "low"},
               developer: %{model: "other-developer", effort: "medium"},
               reviewer: %{model: "other-reviewer", effort: "high"},
               helpers: %{
                 scout: %{model: "other-scout", effort: "low"},
                 worker: %{model: "other-worker", effort: "low"},
                 expert: %{model: "other-expert", effort: "high"}
               },
               outer_resumptions: 1,
               verification_retries: 0
             }

      assert {:ok, codex} = Intent.read_config(path, "codex")
      assert codex.route == "codex"
      assert codex.shaping == %{model: "fable", effort: "medium"}
      assert codex.helpers.expert == %{model: "expert", effort: "medium"}

      assert {:ok, claude} = Intent.read_config(path, "claude")
      assert claude.harness == "claude"
      assert claude.helpers.scout == %{model: "claude-sonnet-5", effort: "low"}

      # The global retry policy applies to every route.
      for config <- [codex, claude, other] do
        assert {config.outer_resumptions, config.verification_retries} == {1, 0}
      end
    end

    test "retries inside a route are not a substitute for the global retry policy" do
      dir = tmp_dir!()
      route = @valid_route <> "outer_resumptions: 2\nverification_retries: 2\n"
      path = write_yaml!(dir, "config.yaml", routes_config([{"codex", route}], tail: ""))

      assert {:error, "config.yaml missing required key: outer_resumptions"} =
               Intent.read_config(path)
    end

    test "the flat configuration shape is refused with a message naming default_route and routes" do
      dir = tmp_dir!()
      flat = "harness: codex\n" <> String.replace(@valid_route, "harness: codex\n", "")

      for yaml <- [
            flat <> "outer_resumptions: 2\nverification_retries: 2\n",
            String.replace(flat, "harness: codex\n", "") <> "outer_resumptions: 2\n",
            "default_route: codex\nharness: codex\n",
            "outer_resumptions: 2\nverification_retries: 2\n"
          ] do
        path = write_yaml!(dir, "flat.yaml", yaml)
        assert {:error, @flat_config_error} = Intent.read_config(path)
        assert {:error, @flat_config_error} = Intent.read_config(path, "codex")
      end

      assert @flat_config_error =~ "default_route"
      assert @flat_config_error =~ "routes"
    end

    test "a missing or unknown default_route is refused, never replaced by the first route" do
      dir = tmp_dir!()
      routes = [{"codex", @valid_route}, {"other", @other_route}]

      missing = write_yaml!(dir, "missing.yaml", routes_config(routes, default_route: nil))
      unknown = write_yaml!(dir, "unknown.yaml", routes_config(routes, default_route: "gone"))
      blank = write_yaml!(dir, "blank.yaml", routes_config(routes, default_route: "''"))

      assert {:error, "config.yaml missing required key: default_route"} =
               Intent.read_config(missing)

      assert {:error, "config.yaml missing required key: default_route"} =
               Intent.read_config(missing, "codex")

      assert {:error,
              "config.yaml default_route names unknown route: gone; available routes: codex, other"} =
               Intent.read_config(unknown)

      assert {:error, "config.yaml missing required key: default_route"} =
               Intent.read_config(blank)
    end

    test "an unknown requested route lists the available routes in sorted order" do
      dir = tmp_dir!()

      path =
        write_yaml!(
          dir,
          "config.yaml",
          routes_config([{"zeta", @valid_route}, {"alpha", @other_route}, {"mid", @valid_route}])
        )

      assert {:error, "unknown route: missing; available routes: alpha, mid, zeta"} =
               Intent.read_config(path, "missing")
    end

    test "a structurally broken unselected route is refused with its key path" do
      dir = tmp_dir!()

      broken = [
        {String.replace(@other_route, "harness: codex\n", ""), "routes.other.harness"},
        {String.replace(@other_route, "harness: codex", "harness: ''"), "routes.other.harness"},
        {String.replace(@other_route, "reviewer:  {model: other-reviewer, effort: high}\n", ""),
         "routes.other.reviewer"},
        {String.replace(@other_route, "{model: other-worker, effort: low}", "{effort: low}"),
         "routes.other.helpers.worker.model"},
        {String.replace(
           @other_route,
           "{model: other-scout, effort: low}",
           "{model: s, effort: 7}"
         ), "routes.other.helpers.scout.effort"},
        {String.replace(
           @other_route,
           "{model: other-shaper, effort: low}",
           "{model: '  ', effort: low}"
         ), "routes.other.shaping.model"}
      ]

      for {route, key_path} <- broken do
        path =
          write_yaml!(
            dir,
            "broken.yaml",
            routes_config([{"codex", @valid_route}, {"other", route}])
          )

        expected = "config.yaml missing required key: #{key_path}"
        assert {:error, ^expected} = Intent.read_config(path)
        assert {:error, ^expected} = Intent.read_config(path, "codex")
      end

      not_a_map = write_yaml!(dir, "scalar.yaml", routes_config([{"codex", @valid_route}]) <> "")

      File.write!(
        not_a_map,
        String.replace(File.read!(not_a_map), "routes:\n", "routes:\n  other: scalar\n")
      )

      assert {:error, "config.yaml missing required key: routes.other"} =
               Intent.read_config(not_a_map)
    end

    test "harness support and proven models are checked only for the selected route" do
      dir = tmp_dir!()
      pi = String.replace(@other_route, "harness: codex", "harness: pi-chatgpt")

      unproven =
        String.replace(
          @claude_route,
          "shaping:   {model: claude-opus-5-5, effort: medium}",
          "shaping:   {model: claude-unproven-9, effort: medium}"
        )

      path =
        write_yaml!(
          dir,
          "config.yaml",
          routes_config([{"codex", @valid_route}, {"pi", pi}, {"unproven", unproven}])
        )

      assert {:ok, %{route: "codex", harness: "codex"}} = Intent.read_config(path)

      assert {:error, "unsupported harness: pi-chatgpt; expected codex or claude"} =
               Intent.read_config(path, "pi")

      assert {:error, reason} = Intent.read_config(path, "unproven")
      assert reason =~ "unsupported Claude Code model for shaping: claude-unproven-9"
    end

    test "routes keep the resolved map shape with an explicit harness and no defaulted keys" do
      dir = tmp_dir!()
      path = write_yaml!(dir, "config.yaml", @valid_config)

      assert {:ok, config} = Intent.read_config(path)

      assert Map.keys(config) |> Enum.sort() ==
               ~w(developer harness helpers outer_resumptions reviewer route shaping verification_retries)a
    end
  end

  describe "read_draft/1 route provenance" do
    # read_draft/1 reads relative to the working directory; run it in a child VM.
    test "legacy and route-bearing Drafts are both continuable" do
      dir = tmp_dir!()

      for {slug, route_line} <- [{"legacy-draft", ""}, {"routed-draft", "  route: codex\n"}] do
        write_yaml!(dir, ".kogen/intents/drafts/#{slug}/intent.yaml", """
        id: 01a0711c-5df0-7822-925c-640efbec8e6c
        slug: #{slug}
        title: Draft
        shaped_against: {branch: main, head: abc123}
        shaping:
        #{route_line}  harness: claude
          model: claude-opus-5-5
          effort: medium
          started: '2026-09-23T07:45:41Z'
        """)
      end

      script = """
      {:ok, _apps} = Application.ensure_all_started(:yaml_elixir)

      for slug <- ["legacy-draft", "routed-draft"] do
        {:ok, draft} = Kogen.Intent.read_draft(slug)
        IO.puts(slug <> "=" <> draft.shaping["harness"])
      end
      """

      code_paths =
        Enum.flat_map(:code.get_path(), fn path ->
          path = to_string(path)
          if String.contains?(path, "_build"), do: ["-pa", path], else: []
        end)

      {output, status} =
        System.cmd("elixir", code_paths ++ ["-e", script], cd: dir, stderr_to_stdout: true)

      assert status == 0, output
      assert output =~ "legacy-draft=claude"
      assert output =~ "routed-draft=claude"
    end
  end
end
