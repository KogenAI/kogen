defmodule Kogen.FakeJev do
  @moduledoc false

  # Offline TypeSafe Jev fixtures. In-process tests inject `transport/1`, a
  # replay of recorded transport results; Build fixtures select the
  # `test/support/fake_jev` executable and `test/support/fake_security`
  # through KOGEN_JEV_TRANSPORT / KOGEN_JEV_SECURITY. Neither opens a network
  # connection, and both use a sentinel key that must never be retained.

  @sentinel "kogen-offline-sentinel-jev-key"

  # The exact undocumented HTTP 400 body TypeSafe returned for oversized
  # requests during Shaping calibration (evidence/jev-calibration.md).
  @max_tokens_body ~s({"detail":{"error_type":"max_tokens_exceeded"}})

  def sentinel_key, do: @sentinel
  def max_tokens_body, do: @max_tokens_body

  def root, do: System.get_env("KOGEN_TEST_ROOT") || Path.expand("../..", __DIR__)
  def transport_path, do: Path.join(root(), "test/support/fake_jev")
  def security_path, do: Path.join(root(), "test/support/fake_security")

  @doc """
  A transport function replaying `results` in order (the last one repeats).
  Each request (with its headers) is sent to `owner` as `{:jev_request, req}`.
  """
  def transport(results, owner \\ self()) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn request ->
      send(owner, {:jev_request, request})

      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
      |> case do
        {:timeout} -> {:error, :timeout}
        {:error, reason} -> {:error, reason}
        {status, body} -> {:ok, %{status: status, body: body}}
      end
    end
  end

  @doc "A valid answer body for `items`, with per-question overrides."
  def answer_body(items, overrides \\ %{}, model \\ "jev-1.13.0") do
    answers =
      items
      |> Kogen.Jev.question_options()
      |> Map.new(fn {id, _options} ->
        {choice, confidence} = Map.get_lazy(overrides, id, fn -> default_answer(id) end)
        {id, %{"type" => "choice", "choice" => choice, "confidence" => confidence}}
      end)

    Jason.encode!(%{
      "model" => model,
      "answers" => answers,
      "usage" => %{"input_tokens" => 100, "output_tokens" => 0}
    })
  end

  defp default_answer("status:" <> _id), do: {"done", 0.97}
  defp default_answer(_id), do: {"no_objection", 0.98}

  @doc "Requests logged by the fake executable, oldest first."
  def requests(log_dir) do
    log_dir
    |> Path.join("request-*.json")
    |> Path.wildcard()
    |> Enum.sort_by(
      &(&1
        |> Path.basename(".json")
        |> String.split("-")
        |> List.last()
        |> String.to_integer())
    )
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  @doc "Writes recorded transport results for the fake executable, one per call."
  def record_responses!(dir, results) do
    File.mkdir_p!(dir)

    results
    |> Enum.with_index(1)
    |> Enum.each(fn {result, index} ->
      encoded =
        case result do
          {:timeout} -> %{"error" => "timeout"}
          {:error, reason} -> %{"error" => reason}
          {status, body} -> %{"status" => status, "body" => body}
        end

      File.write!(Path.join(dir, "#{index}.json"), Jason.encode!(encoded))
    end)

    dir
  end
end
