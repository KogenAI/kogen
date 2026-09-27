defmodule Kogen.ShapingAudit.FakeJevAudit do
  @moduledoc false

  # In-process fakes for the Shaping audit's `Kogen.Jev.ask/3` requests.
  # `answering/2` reads each request's own inline `type`/`criteria` (there is
  # no fixed `status:`/`objection:` id scheme, unlike the Build handoff) and
  # answers every asked question, by default or by override. `replay/2`
  # replays a fixed list of raw transport results, like `Kogen.FakeJev`, for
  # exercising every HTTP/timeout failure mode. Both log every request (with
  # headers) to `owner` as `{:jev_request, request}` and never touch the
  # network. The subprocess fakes `test/support/shaping_audit/fake_jev_audit`
  # and `test/support/shaping_audit/fake_security_audit` exercise the same
  # contract end-to-end, through KOGEN_JEV_TRANSPORT/KOGEN_JEV_SECURITY.

  @sentinel "kogen-offline-sentinel-jev-key"

  def sentinel_key, do: @sentinel

  def root, do: System.get_env("KOGEN_TEST_ROOT") || Path.expand("../../..", __DIR__)
  def transport_path, do: Path.join(root(), "test/support/shaping_audit/fake_jev_audit")
  def security_path, do: Path.join(root(), "test/support/shaping_audit/fake_security_audit")

  @doc """
  A transport answering every question in every request: an override
  `%{question_id => {choice, confidence} | confidence}` (Noul), or else the
  first criteria option at confidence 0.9 (Choice) or 0.05 (Noul).
  """
  def answering(overrides \\ %{}, owner \\ self()) do
    fn request ->
      send(owner, {:jev_request, request})
      body = Jason.decode!(request.body)

      answers =
        Map.new(body["questions"], fn {id, spec} -> {id, answer_for(id, spec, overrides)} end)

      response =
        Jason.encode!(%{
          "model" => body["model"],
          "answers" => answers,
          "usage" => %{"input_tokens" => byte_size(request.body) |> div(4), "output_tokens" => 0}
        })

      {:ok, %{status: 200, body: response}}
    end
  end

  defp answer_for(id, %{"type" => "noul"}, overrides) do
    noul = Map.get(overrides, id, 0.05)
    %{"type" => "noul", "noul" => noul}
  end

  defp answer_for(id, %{"type" => "choice", "criteria" => criteria}, overrides) do
    # Erlang map key order is randomized per VM instance for maps beyond a
    # few entries; sort explicitly so the un-overridden default is the same
    # answer on every run.
    options = criteria |> Map.keys() |> Enum.sort()

    {choice, confidence, probabilities} =
      case Map.get(overrides, id) do
        nil -> {List.first(options), 0.9, nil}
        {choice, confidence} -> {choice, confidence, nil}
        {choice, confidence, probabilities} -> {choice, confidence, probabilities}
      end

    %{
      "type" => "choice",
      "choice" => choice,
      "confidence" => confidence,
      "probabilities" => probabilities || uniform(options, choice, confidence)
    }
  end

  defp uniform(options, choice, confidence) do
    rest = max(length(options) - 1, 1)

    Map.new(options, fn option ->
      {option, if(option == choice, do: confidence, else: (1 - confidence) / rest)}
    end)
  end

  @doc "A transport replaying `results` in order (the last one repeats), like `Kogen.FakeJev.transport/2`."
  def replay(results, owner \\ self()) do
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
end
