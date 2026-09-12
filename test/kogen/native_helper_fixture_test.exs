Code.require_file("../support/native_helper_fixture.ex", __DIR__)

defmodule Kogen.NativeHelperFixtureTest do
  use ExUnit.Case, async: true

  alias Kogen.NativeHelperFixture

  test "renders the bounded packets through the production role renderer" do
    {:ok, config} = Kogen.Intent.read_config()
    prompt = NativeHelperFixture.prompt(config, "developer")

    assert prompt =~ "Configured root (developer): `gpt-5.6-sol` at `low`"
    assert prompt =~ "fresh_scout_route"
    assert prompt =~ "agent_type `explorer`"
    assert prompt =~ "agent_type `worker`"
    assert prompt =~ "agent_type `default`"
    assert prompt =~ "gpt-5.6-luna"
    assert prompt =~ "gpt-5.6-sol"
    assert prompt =~ "Read-only boundary"
    refute prompt =~ "r17"
    refute prompt =~ "provider_error"
  end

  test "accepts only complete runner-owned native metadata and task facts" do
    {:ok, config} = Kogen.Intent.read_config()
    protocol = NativeHelperFixture.protocol(config, "developer")
    receipt = valid_receipt(protocol)

    assert :ok = NativeHelperFixture.validate_receipt(receipt, protocol)

    for mutation <- [
          fn receipt -> put_in(receipt, ["children"], Enum.drop(receipt["children"], 1)) end,
          fn receipt ->
            put_in(receipt, ["children", Access.at(0), "observed_profiles"], [["wrong", "low"]])
          end,
          fn receipt ->
            put_in(receipt, ["children", Access.at(0), "parent_id"], "unrelated-parent")
          end,
          fn receipt -> put_in(receipt, ["children", Access.at(0), "complete"], false) end,
          fn receipt ->
            put_in(receipt, ["children", Access.at(0), "requested_kind"], "expert")
          end,
          fn receipt ->
            put_in(receipt, ["children", Access.at(0), "observed_task"], %{
              "model" => "self-reported"
            })
          end,
          fn receipt -> Map.put(receipt, "fixture_unchanged", false) end
        ] do
      assert {:error, _reason} =
               receipt |> mutation.() |> NativeHelperFixture.validate_receipt(protocol)
    end
  end

  test "collects only the Harness-known parent and its exact native children" do
    {:ok, config} = Kogen.Intent.read_config()
    protocol = NativeHelperFixture.protocol(config, "developer")
    root = tmp_dir!()
    fixture = NativeHelperFixture.write_fixture!(root)
    sessions = Path.join(root, "sessions")
    raw = Path.join(root, "raw")
    File.mkdir_p!(sessions)
    write_session!(Path.join(sessions, "parent.jsonl"), parent_rows(protocol))

    Enum.each(protocol["children"], fn task ->
      write_session!(Path.join(sessions, task["name"] <> ".jsonl"), child_rows(task))
    end)

    # Imported historical rollouts can duplicate IDs unrelated to this run.
    historical = [%{"type" => "session_meta", "payload" => %{"id" => "old-unrelated"}}]
    write_session!(Path.join(sessions, "old-a.jsonl"), historical)
    write_session!(Path.join(sessions, "old-b.jsonl"), historical)

    receipt =
      NativeHelperFixture.collect_receipt!(sessions, raw, "parent-thread", fixture, protocol)

    assert :ok = NativeHelperFixture.validate_receipt(receipt, protocol)
    assert File.regular?(Path.join(raw, "parent.jsonl"))
    assert length(Path.wildcard(Path.join(raw, "fresh_*.jsonl"))) == 3

    write_session!(
      Path.join(sessions, "nested.jsonl"),
      [
        %{
          "type" => "session_meta",
          "payload" => %{
            "id" => "nested-child",
            "parent_thread_id" => "child-fresh_scout_route",
            "agent_path" => "/root/fresh_scout_route/unexpected"
          }
        }
      ]
    )

    assert_raise ArgumentError, ~r/unexpected descendant/, fn ->
      NativeHelperFixture.collect_receipt!(sessions, raw, "parent-thread", fixture, protocol)
    end
  end

  test "native collector rejects incomplete or mismatched records and fixture additions" do
    {:ok, config} = Kogen.Intent.read_config()
    protocol = NativeHelperFixture.protocol(config, "developer")
    root = tmp_dir!()
    fixture = NativeHelperFixture.write_fixture!(root)
    sessions = Path.join(root, "sessions")
    File.mkdir_p!(sessions)
    write_session!(Path.join(sessions, "parent.jsonl"), parent_rows(protocol))

    Enum.each(protocol["children"], fn task ->
      write_session!(Path.join(sessions, task["name"] <> ".jsonl"), child_rows(task))
    end)

    task = hd(protocol["children"])
    child_path = Path.join(sessions, task["name"] <> ".jsonl")

    for rows <- [
          Enum.reject(child_rows(task), &(&1["type"] == "turn_context")),
          Enum.reject(child_rows(task), &(get_in(&1, ["payload", "type"]) == "task_complete")),
          child_rows(task) ++ [%{"type" => "turn_context", "payload" => %{"model" => "wrong"}}]
        ] do
      write_session!(child_path, rows)

      receipt =
        NativeHelperFixture.collect_receipt!(
          sessions,
          Path.join(root, "raw"),
          "parent-thread",
          fixture,
          protocol
        )

      assert {:error, _} = NativeHelperFixture.validate_receipt(receipt, protocol)
    end

    write_session!(child_path, child_rows(task))
    File.mkdir!(Path.join(fixture, "unexpected-empty-directory"))

    receipt =
      NativeHelperFixture.collect_receipt!(
        sessions,
        Path.join(root, "raw"),
        "parent-thread",
        fixture,
        protocol
      )

    assert {:error, _} = NativeHelperFixture.validate_receipt(receipt, protocol)

    File.rm!(child_path)

    assert_raise ArgumentError, ~r/missing/, fn ->
      NativeHelperFixture.collect_receipt!(
        sessions,
        Path.join(root, "raw"),
        "parent-thread",
        fixture,
        protocol
      )
    end
  end

  defp valid_receipt(protocol) do
    %{
      "parent_id" => "parent-thread",
      "parent_profile" => protocol["parent_profile"],
      "parent_source_sha256" => "parent-source-digest",
      "fixture_sha256" => protocol["fixture_sha256"],
      "fixture_unchanged" => true,
      "children" =>
        Enum.map(protocol["children"], fn task ->
          %{
            "name" => task["name"],
            "parent_id" => "parent-thread",
            "child_id" => "child-#{task["name"]}",
            "requested_kind" => task["kind"],
            "requested_model" => task["model"],
            "requested_effort" => task["effort"],
            "requested_fork_turns" => "none",
            "observed_profiles" => [[task["model"], task["effort"]]],
            "complete" => true,
            "source_sha256" => "child-source-digest",
            "observed_task" => task["expected"]
          }
        end)
    }
  end

  defp parent_rows(protocol) do
    calls =
      Enum.map(protocol["children"], fn task ->
        %{
          "type" => "response_item",
          "payload" => %{
            "type" => "function_call",
            "name" => "spawn_agent",
            "arguments" =>
              Jason.encode!(%{
                "task_name" => task["name"],
                "agent_type" => task["kind"],
                "model" => task["model"],
                "reasoning_effort" => task["effort"],
                "fork_turns" => "none"
              })
          }
        }
      end)

    [
      %{"type" => "session_meta", "payload" => %{"id" => "parent-thread"}},
      %{"type" => "turn_context", "payload" => protocol["parent_profile"]}
      | calls
    ]
  end

  defp child_rows(task) do
    answer = Jason.encode!(task["expected"])

    [
      %{
        "type" => "session_meta",
        "payload" => %{
          "id" => "child-#{task["name"]}",
          "parent_thread_id" => "parent-thread",
          "agent_path" => "/root/#{task["name"]}"
        }
      },
      %{
        "type" => "turn_context",
        "payload" => %{"model" => task["model"], "effort" => task["effort"]}
      },
      %{
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "assistant",
          "channel" => "final",
          "content" => [%{"type" => "output_text", "text" => answer}]
        }
      },
      %{
        "type" => "event_msg",
        "payload" => %{"type" => "task_complete", "last_agent_message" => answer}
      }
    ]
  end

  defp write_session!(path, rows) do
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "native-helper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
