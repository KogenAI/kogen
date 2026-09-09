defmodule Kogen.VerificationPolicy do
  @moduledoc """
  The Build-side half of the Developer verification guard.

  The PreToolUse hook performs command classification before Codex dispatches a
  Bash request. This module derives the immutable policy passed to that hook
  and proves the tracked hook is installed before a Developer is launched.
  """
  use Boundary, deps: [Kogen.Check]

  @hooks_path ".codex/hooks.json"
  @script_path ".codex/hooks/verification_policy.py"
  @stop_script_path ".codex/hooks/check.sh"
  @hook_command "python3 \"$(git rev-parse --show-toplevel)/.codex/hooks/verification_policy.py\""

  @spec normalized_targets([String.t()]) :: [String.t()]
  def normalized_targets(targets), do: Enum.uniq(["check", "live" | targets])

  @spec environment([String.t()], Path.t()) :: [{String.t(), String.t()}]
  def environment(targets, root \\ File.cwd!()) do
    [
      {"KOGEN_VERIFICATION_TARGETS", Jason.encode!(normalized_targets(targets))},
      {"KOGEN_PROJECT_ROOT", root}
    ]
  end

  @spec preflight([String.t()], Path.t()) :: :ok | {:error, String.t()}
  def preflight(targets, root \\ ".")

  def preflight(targets, root) when is_list(targets) do
    with true <- Enum.all?(normalized_targets(targets), &Kogen.Check.valid_target_name?/1),
         :ok <- required_file(@script_path, root),
         :ok <- required_file(@stop_script_path, root),
         :ok <- registered_hook(root) do
      :ok
    else
      false -> {:error, "verification policy has an invalid target name"}
      {:error, _reason} = error -> error
    end
  end

  def preflight(_, _root), do: {:error, "verification policy targets are missing or invalid"}

  @spec developer_instruction([String.t()]) :: String.t()
  def developer_instruction(targets) do
    names = Enum.map_join(normalized_targets(targets), ", ", &"`make #{&1}`")

    "Kogen machinery owns verification gates. Do not run #{names}, the Stop script " <>
      "`.codex/hooks/check.sh`, or any indirect equivalent — including for early signal " <>
      "or through delegated helpers. Focused non-gate tests remain allowed."
  end

  defp required_file(path, root) do
    if File.regular?(Path.join(root, path)),
      do: :ok,
      else: {:error, "required verification policy file is missing: #{path}"}
  end

  defp registered_hook(root) do
    with {:ok, contents} <- File.read(Path.join(root, @hooks_path)),
         {:ok, json} <- Jason.decode(contents),
         true <- pretooluse_registration?(json) do
      :ok
    else
      _ -> {:error, "required Developer Bash verification-policy hook is not registered"}
    end
  end

  defp pretooluse_registration?(%{"hooks" => %{"PreToolUse" => entries}}) when is_list(entries) do
    Enum.any?(entries, fn
      %{"matcher" => "Bash", "hooks" => hooks} when is_list(hooks) ->
        Enum.any?(hooks, fn
          %{"type" => "command", "command" => @hook_command} ->
            true

          _ ->
            false
        end)

      _ ->
        false
    end)
  end

  defp pretooluse_registration?(_), do: false
end
