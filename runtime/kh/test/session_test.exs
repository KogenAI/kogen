defmodule Kh.SessionTest do
  use ExUnit.Case, async: false
  import Bitwise

  test "scripted replies run real tools, preserve unknown usage and restore for appended input" do
    root = temp_dir!()
    checkpoint = Path.join(root, "session.json")

    replies = [
      %{
        "expect" => %{"last_user_text" => "write a marker"},
        "reply" => %{
          "tool_calls" => [
            %{
              "name" => "write",
              "args" => %{"path" => "marker.txt", "content" => "created by tool"}
            }
          ]
        }
      },
      %{
        "expect" => %{"last_tool_name" => "write", "last_tool_is_error" => false},
        "reply" => %{"text" => "marker created"}
      }
    ]

    {:ok, session} = Kh.Session.open(session_config(root, checkpoint, replies))
    {:ok, run_ref} = Kh.Session.run(session, "write a marker")
    {:ok, result} = Kh.Session.await(session, run_ref, 5_000)

    assert get_in(result, ["summary", "status"]) == "ok"
    assert get_in(result, ["summary", "final_text"]) == "marker created"
    assert File.read!(Path.join(root, "marker.txt")) == "created by tool"
    assert get_in(result, ["evidence", "usage_state"]) == "partial"
    assert get_in(result, ["evidence", "usage"]) == nil
    assert get_in(result, ["summary", "usage"]) == nil
    assert get_in(result, ["summary", "cost_usd"]) == nil
    assert get_in(result, ["summary", "cost_usd_successful_turns"]) == nil
    assert get_in(result, ["summary", "cost_usd_failed_attempts"]) == nil
    assert {:ok, saved_checkpoint} = Kh.Checkpoint.load(checkpoint)
    assert saved_checkpoint.cost == nil
    run_end = Enum.find(result["events"], &(&1["type"] == "run_end"))["data"]
    assert run_end["usage"] == nil
    assert run_end["usage_total"] == nil
    assert run_end["usage_state"] == "partial"
    assert get_in(result, ["evidence", "checkpoint_phase"]) == "complete"
    assert get_in(result, ["evidence", "session_id"]) == get_in(result, ["session_id"])

    original_session_id = get_in(result, ["session_id"])
    assert (File.stat!(checkpoint).mode &&& 0o777) == 0o600
    GenServer.stop(session)

    fresh_replies = [
      %{
        "expect" => %{"last_user_text" => "continue this session"},
        "reply" => %{
          "text" => "continued",
          "usage" => %{
            "input" => 9,
            "cached_input" => 2,
            "cache_write" => 0,
            "output" => 3,
            "reasoning" => 1
          }
        }
      }
    ]

    restore_config =
      session_config(root, checkpoint, fresh_replies)
      |> Map.put(:restore_from, checkpoint)

    parent = self()
    changed_model = Map.put(restore_config, :model, "different-model")
    {opener, open_ref} =
      spawn_monitor(fn -> send(parent, {:restore_result, Kh.Session.open(changed_model)}) end)

    assert_receive {:restore_result, {:error, "checkpoint model does not match"}}, 5_000
    assert_receive {:DOWN, ^open_ref, :process, ^opener, :normal}, 5_000
    assert Process.alive?(self())

    {:ok, restored} =
      restore_config
      |> Kh.Session.open()

    assert Kh.Session.evidence(restored)["session_id"] == original_session_id
    {:ok, continued_ref} = Kh.Session.append_input(restored, "continue this session")
    {:ok, continued} = Kh.Session.await(restored, continued_ref, 5_000)
    assert get_in(continued, ["summary", "final_text"]) == "continued"
    assert get_in(continued, ["evidence", "usage_state"]) == "reported"
    assert get_in(continued, ["evidence", "usage", "input"]) == 9
    assert get_in(continued, ["evidence", "session_id"]) == original_session_id
    GenServer.stop(restored)
  end

  test "script mismatch fails closed without invoking a live provider" do
    root = temp_dir!()
    checkpoint = Path.join(root, "session.json")

    script = [
      %{
        "expect" => %{"last_user_text" => "different prompt"},
        "reply" => %{"text" => "must not run"}
      }
    ]

    {:ok, session} = Kh.Session.open(session_config(root, checkpoint, script))
    {:ok, run_ref} = Kh.Session.run(session, "unexpected prompt")
    {:ok, result} = Kh.Session.await(session, run_ref, 5_000)

    assert get_in(result, ["summary", "status"]) == "error"
    assert get_in(result, ["summary", "error_kind"]) == "fatal"
    assert get_in(result, ["evidence", "scripted_requests"]) == 1
    assert get_in(result, ["events"]) |> Enum.any?(&(&1["type"] == "run_end"))
    GenServer.stop(session)
  end

  test "strict scripted request proves max remains max for supported models" do
    root = temp_dir!()
    checkpoint = Path.join(root, "session.json")
    replies = [
      %{
        "expect" => %{"last_user_text" => "use max", "effort_sent" => "max"},
        "reply" => %{"text" => "max preserved"}
      }
    ]

    config = session_config(root, checkpoint, replies) |> Map.merge(%{model: "gpt-6-luna", effort: "max"})
    {:ok, session} = Kh.Session.open(config)
    {:ok, run_ref} = Kh.Session.run(session, "use max")
    {:ok, result} = Kh.Session.await(session, run_ref, 5_000)
    start = Enum.find(result["events"], &(&1["type"] == "run_start"))["data"]
    assert start["effort_requested"] == "max"
    assert start["effort_sent"] == "max"
    assert result["summary"]["final_text"] == "max preserved"
    GenServer.stop(session)

    assert {:error, message} =
             session_config(root, Path.join(root, "unsupported.json"), replies)
             |> Map.merge(%{model: "gpt-5.5", effort: "max"})
             |> Kh.Session.open()

    assert message =~ "unsupported ChatGPT effort"
  end

  test "ChatGPT admission requires caller credentials and never stores them in session state" do
    root = temp_dir!()
    base = %{
      provider: :chatgpt,
      model: "gpt-6.1-sol",
      cwd: root,
      system_prompt: "The test system prompt.",
      checkpoint_path: Path.join(root, "chatgpt.json")
    }

    assert {:error, missing} = Kh.Session.open(base)
    assert missing =~ "caller-supplied access_token and account_id"

    payload = Base.url_encode64(JSON.encode!(%{"exp" => System.os_time(:second) + 10}), padding: false)
    expiring = "header.#{payload}.signature"

    assert {:error, expiring_error} =
             base
             |> Map.merge(%{access_token: expiring, account_id: "account-test"})
             |> Kh.Session.open()

    assert expiring_error =~ "expires within 60 seconds"

    token = "opaque-token-test-value"
    account = "private-account-test-value"
    {:ok, session} = base |> Map.merge(%{access_token: token, account_id: account}) |> Kh.Session.open()
    state = :sys.get_state(session)
    refute inspect(state) =~ token
    refute inspect(state) =~ account
    refute Map.has_key?(state.config, :access_token)
    refute Map.has_key?(state.config, :account_id)
    GenServer.stop(session)
  end

  test "cancel stops a running tool and records a resumable checkpoint" do
    root = temp_dir!()
    checkpoint = Path.join(root, "session.json")
    owner = self()

    replies = [
      %{
        "expect" => %{"last_user_text" => "start slow tool"},
        "reply" => %{
          "tool_calls" => [
            %{
              "name" => "bash",
              "args" => %{"command" => "sleep 0.6; printf late > late.txt", "timeout" => 20}
            }
          ]
        }
      }
    ]

    config =
      session_config(root, checkpoint, replies,
        event_sink: fn event -> send(owner, {:kh_event, event}) end
      )

    {:ok, session} = Kh.Session.open(config)
    {:ok, _run_ref} = Kh.Session.run(session, "start slow tool")
    assert_receive {:kh_event, %{"type" => "tool_start"}}, 5_000
    session_id = Kh.Session.evidence(session)["session_id"]
    assert eventually(fn -> Enum.any?(:ets.tab2list(:kh_procs), fn {_pid, id, _group} -> id == session_id end) end)

    assert {:ok, evidence} = Kh.Session.cancel(session)
    assert evidence["status"] == "cancelled"
    assert evidence["resumable"]
    Process.sleep(800)
    refute File.exists?(Path.join(root, "late.txt"))
    GenServer.stop(session)
  end

  test "stopping one session preserves custody for another session's tool" do
    root = temp_dir!()
    {:ok, first} = Kh.Session.open(session_config(root, Path.join(root, "first.json"), []))
    registry_owner = :ets.info(:kh_procs, :owner)

    replies = [
      %{
        "expect" => %{"last_user_text" => "start a slow command"},
        "reply" => %{
          "tool_calls" => [
            %{
              "name" => "bash",
              "args" => %{"command" => "sleep 0.8; printf late > late.txt", "timeout" => 20}
            }
          ]
        }
      }
    ]

    owner = self()
    config =
      session_config(root, Path.join(root, "second.json"), replies,
        event_sink: fn event -> send(owner, {:kh_event, event}) end
      )
    {:ok, second} = Kh.Session.open(config)
    {:ok, run_ref} = Kh.Session.run(second, "start a slow command")
    second_id = Kh.Session.evidence(second)["session_id"]
    assert_receive {:kh_event, %{"type" => "tool_start", "session_id" => ^second_id}}, 5_000

    assert eventually(fn ->
             Enum.any?(:ets.tab2list(:kh_procs), fn {_pid, id, _group} -> id == second_id end)
           end)

    GenServer.stop(first)
    assert {:ok, evidence} = Kh.Session.cancel(second)
    assert evidence["status"] == "cancelled"
    assert evidence["resumable"]
    Process.sleep(1_000)
    refute File.exists?(Path.join(root, "late.txt"))
    assert :ets.whereis(:kh_procs) != :undefined
    assert Process.alive?(registry_owner)

    {:ok, result} = Kh.Session.await(second, run_ref, 5_000)
    assert get_in(result, ["summary", "status"]) == "cancelled"
    GenServer.stop(second)
  end

  test "terminal provider failures persist cumulative elapsed time for resume" do
    root = temp_dir!()
    checkpoint = Path.join(root, "session.json")
    prompt = "run command then fail"
    tool_call = %{
      "expect" => %{"last_user_text" => prompt},
      "reply" => %{
        "tool_calls" => [
          %{"name" => "bash", "args" => %{"command" => "printf x >> tool-runs.txt"}}
        ]
      }
    }
    fail = %{
      "expect" => %{"last_tool_name" => "bash", "last_tool_is_error" => false},
      "reply" => %{"error" => "fatal", "message" => "offline failure"}
    }
    owner = self()
    config =
      session_config(root, checkpoint, [tool_call, fail, fail],
        timeout_s: 5,
        event_sink: fn
          %{"type" => "turn_start"} ->
            Process.sleep(250)
            send(owner, :turn_started)

          _event ->
            :ok
        end
      )

    {:ok, session} = Kh.Session.open(config)
    {:ok, first_ref} = Kh.Session.run(session, prompt)
    {:ok, first} = Kh.Session.await(session, first_ref, 5_000)
    assert_receive :turn_started, 1_000
    assert_receive :turn_started, 1_000
    assert get_in(first, ["summary", "status"]) == "error"
    assert File.read!(Path.join(root, "tool-runs.txt")) == "x"
    first_elapsed = get_in(first, ["evidence", "checkpoint_elapsed_ms"])
    assert is_integer(first_elapsed) and first_elapsed >= 200
    assert get_in(first, ["evidence", "checkpoint_phase"]) == "ready"
    assert get_in(first, ["evidence", "resumable"])
    {:ok, first_checkpoint} = Kh.Checkpoint.load(checkpoint)
    assert first_checkpoint.terminal_status == "error"
    assert first_checkpoint.terminal_error == "offline failure"

    {:ok, second_ref} = Kh.Session.resume(session)
    {:ok, second} = Kh.Session.await(session, second_ref, 5_000)
    assert_receive :turn_started, 1_000
    second_elapsed = get_in(second, ["evidence", "checkpoint_elapsed_ms"])
    assert get_in(second, ["summary", "status"]) == "error"
    assert second_elapsed >= first_elapsed + 200
    assert get_in(second, ["evidence", "checkpoint_phase"]) == "ready"
    assert get_in(second, ["evidence", "scripted_requests"]) == 3
    assert File.read!(Path.join(root, "tool-runs.txt")) == "x"
    GenServer.stop(session)
  end

  defp session_config(root, checkpoint, replies, extra \\ []) do
    Map.merge(
      %{
        provider: :scripted,
        model: "offline-test-model",
        cwd: root,
        system_prompt: "The test system prompt.",
        checkpoint_path: checkpoint,
        scripted_replies: replies,
        timeout_s: 30
      },
      Map.new(extra)
    )
  end

  defp temp_dir! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    path = Path.join(System.tmp_dir!(), "kh-session-test-#{suffix}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
