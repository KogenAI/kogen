defmodule Kogen.Build.Cycle do
  @moduledoc "Pure transition function for one Build attempt."

  alias Kogen.Contracts.Failure

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :approval,
      :stage,
      :repairs_left,
      :provider_retries,
      :last_tree,
      :repair_tree,
      :pending_land,
      :result
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            approval: term(),
            stage: atom(),
            repairs_left: non_neg_integer(),
            provider_retries: non_neg_integer(),
            last_tree: String.t() | nil,
            repair_tree: String.t() | nil,
            pending_land: boolean(),
            result: {atom(), term()} | nil
          }
  end

  @type terminal :: :landed | :failed | :parked
  @type run_stage :: :context | :plan | :develop | :fix | :check | :review | :commit | :land
  @type effect ::
          {:run, run_stage(), map()}
          | {:record, map()}
          | {:finish, terminal(), term()}

  @provider_retries 2
  @stage_success_events [:context, :plan, :develop, :done_gate, :fix, :check]

  @spec new(%{required(:approval) => term(), required(:repairs) => non_neg_integer()}) ::
          State.t()
  def new(%{approval: approval, repairs: repairs}) when is_integer(repairs) and repairs >= 0 do
    %State{
      approval: approval,
      stage: :context,
      repairs_left: repairs,
      provider_retries: 0,
      last_tree: nil,
      repair_tree: nil,
      pending_land: false,
      result: nil
    }
  end

  def new(_options), do: raise(ArgumentError, "cycle requires an approval and repair count")

  @spec step(State.t(), term()) :: {State.t(), [effect()]}
  def step(%State{result: result} = state, _event) when not is_nil(result), do: {state, []}

  def step(state, {:stage_ok, stage, data}) when is_map(data) do
    cond do
      stage == state.stage and stage in @stage_success_events ->
        stage_succeeded(state, stage, data)

      stage == :commit and state.stage == :land ->
        commit_succeeded(state, data)

      true ->
        fail_controller(state, :unexpected_stage_event)
    end
  end

  def step(%State{stage: :review} = state, {:review, verdict, findings})
      when verdict in [:accept, :revise] and is_list(findings) do
    review_result(state, verdict, findings)
  end

  def step(%State{stage: :land, pending_land: true} = state, {:landed, sha})
      when is_binary(sha) do
    finish(state, :landed, sha)
  end

  def step(state, {:base_moved}) do
    finish(state, :parked, :base_moved)
  end

  def step(state, {:stage_failed, stage, %Failure{} = failure}) do
    if (stage == state.stage and stage != :done_gate) or
         (stage == :commit and state.stage == :land) do
      handle_failure(state, stage, failure)
    else
      fail_controller(state, :unexpected_stage_event)
    end
  end

  def step(state, _event), do: fail_controller(state, :unexpected_event)

  defp stage_succeeded(state, :context, _data) do
    next = %{state | stage: :plan}
    {next, [record(:stage_ok, %{stage: :context}), run(:plan, stage_args(next))]}
  end

  defp stage_succeeded(state, :plan, _data) do
    next = %{state | stage: :develop}
    {next, [record(:stage_ok, %{stage: :plan}), run(:develop, stage_args(next))]}
  end

  defp stage_succeeded(state, :develop, data) do
    tree = tree_from(data)

    if same_repaired_tree?(state, tree) do
      fail_candidate(state, :unchanged)
    else
      next = %{state | stage: :done_gate, last_tree: tree, repair_tree: nil}
      {next, [record(:stage_ok)]}
    end
  end

  defp stage_succeeded(state, :done_gate, data) do
    case Map.get(data, :outcome, :done) do
      :done ->
        next = %{state | stage: :fix}
        {next, [record(:stage_ok), run(:fix, stage_args(next))]}

      :gate_red ->
        repair(state, :done_gate_red, %{outcome: :gate_red})

      :gave_up ->
        finish(state, :failed, :developer_gave_up)

      _other ->
        fail_controller(state, :invalid_done_gate)
    end
  end

  defp stage_succeeded(state, :fix, _data) do
    next = %{state | stage: :check}
    {next, [record(:stage_ok), run(:check, stage_args(next))]}
  end

  defp stage_succeeded(state, :check, _data) do
    next = %{state | stage: :review}
    {next, [record(:stage_ok), run(:review, stage_args(next))]}
  end

  defp review_result(state, :accept, findings) do
    next = %{state | stage: :land, pending_land: false}

    {next,
     [
       record(:review_accept, %{findings: findings}),
       run(:commit, stage_args(next, %{findings: findings}))
     ]}
  end

  defp review_result(state, :revise, findings) do
    repair(state, :review_revise, %{findings: findings})
  end

  defp commit_succeeded(state, data) do
    case landing_identity(data) do
      {:ok, identity} ->
        next = %{state | pending_land: true}

        {next,
         [
           {:record, %{event: :landing_prepared, landing: identity}},
           run(:land, identity)
         ]}

      :error ->
        fail_controller(state, :missing_landing_identity)
    end
  end

  defp landing_identity(data) do
    keys = [:approval_commit, :run_id, :expected_parent, :final_tree, :candidate_commit]

    if Enum.all?(keys, &is_binary(Map.get(data, &1))) do
      {:ok, Map.new(keys, &{&1, Map.fetch!(data, &1)})}
    else
      :error
    end
  end

  defp handle_failure(state, stage, %Failure{class: :candidate, reason: reason}) do
    repair(state, reason, %{failed_stage: stage})
  end

  defp handle_failure(state, _stage, %Failure{class: :environment, reason: reason}) do
    finish(state, :failed, {:environment, reason})
  end

  defp handle_failure(state, stage, %Failure{class: :provider, reason: reason}) do
    if state.provider_retries < @provider_retries do
      {retry_state_stage, retry_run_stage} = provider_retry_target(stage)
      provider_retries = state.provider_retries + 1

      next = %{
        state
        | stage: retry_state_stage,
          provider_retries: provider_retries,
          pending_land: false
      }

      {next,
       [
         record(:provider_retry, %{stage: stage, reason: reason}),
         run(retry_run_stage, stage_args(next, %{provider_retry: provider_retries}))
       ]}
    else
      finish(state, :failed, {:provider_retries_exhausted, reason})
    end
  end

  defp handle_failure(state, _stage, %Failure{class: :controller, reason: reason}) do
    finish(state, :failed, {:controller, reason})
  end

  defp handle_failure(state, _stage, %Failure{}),
    do: finish(state, :failed, {:controller, :unknown_failure_class})

  defp provider_retry_target(stage) when stage in [:commit, :land], do: {:land, :commit}
  defp provider_retry_target(stage), do: {stage, stage}

  defp repair(state, reason, detail) do
    if state.repairs_left == 0 do
      fail_candidate(state, :repair_cap)
    else
      next = %{
        state
        | stage: :develop,
          repairs_left: state.repairs_left - 1,
          repair_tree: state.last_tree,
          pending_land: false
      }

      {next,
       [
         record(:repair, %{reason: reason, repairs_left: next.repairs_left, detail: detail}),
         run(:develop, stage_args(next, %{repair: detail, reason: reason}))
       ]}
    end
  end

  defp fail_candidate(state, reason), do: finish(state, :failed, reason)

  defp fail_controller(state, reason) do
    finish(state, :failed, {:controller, reason})
  end

  defp finish(state, status, reason) do
    next_stage = status
    next = %{state | stage: next_stage, result: {status, reason}, pending_land: false}

    {next,
     [
       record(:finished, %{status: status, reason: reason}),
       {:finish, status, reason}
     ]}
  end

  defp same_repaired_tree?(%State{repair_tree: nil}, _tree), do: false
  defp same_repaired_tree?(%State{repair_tree: tree}, tree) when is_binary(tree), do: true
  defp same_repaired_tree?(_state, _tree), do: false

  defp tree_from(data) do
    Map.get(data, :tree) || Map.get(data, :candidate_tree)
  end

  defp stage_args(state, extra \\ %{}) do
    Map.merge(
      %{
        approval: state.approval,
        repairs_left: state.repairs_left,
        provider_retries: state.provider_retries
      },
      extra
    )
  end

  defp run(stage, args), do: {:run, stage, args}
  defp record(event), do: {:record, %{event: event}}
  defp record(event, data), do: {:record, Map.merge(%{event: event}, data)}
end
