defmodule Kogen.Provider.ChatGPT.KeychainStore do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc

  @security "/usr/bin/security"
  @service "kogen"
  @timeout_ms 15_000

  @spec available?() :: boolean()
  def available?, do: File.regular?(@security)

  @spec read(Path.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(root, label) do
    with :ok <- prepare_root(root),
         {:ok, output} <-
           command(root, ["find-generic-password", "-s", @service, "-a", account(label), "-w"]) do
      decode(output)
    end
  end

  @spec write(Path.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write(root, label, contents) when is_binary(contents) do
    with :ok <- prepare_root(root) do
      case run_security(
             ["add-generic-password", "-U", "-s", @service, "-a", account(label), "-w"],
             Base.encode64(contents) <> "\n",
             root
           ) do
        {:ok, _output} -> :ok
        {:error, reason, _output} -> {:error, reason}
      end
    end
  end

  @spec delete(Path.t(), String.t()) :: :ok | {:error, term()}
  def delete(root, label) do
    with :ok <- prepare_root(root) do
      case command(root, ["delete-generic-password", "-s", @service, "-a", account(label)]) do
        {:ok, _output} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp command(root, args) do
    case run_security(args, nil, root) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason, output} ->
        if String.contains?(output, "could not be found"),
          do: {:error, :not_found},
          else: {:error, reason}
    end
  end

  defp prepare_root(root) do
    with :ok <- File.mkdir_p(root), do: File.chmod(root, 0o700)
  end

  defp run_security(args, input, directory) do
    if available?() do
      opts = [cd: directory, env: %{}, timeout_ms: @timeout_ms]
      opts = if is_binary(input), do: Keyword.put(opts, :stdin, {:binary, input}), else: opts

      case Proc.run([@security | args], opts) do
        {:ok, %ProcResult{exit_status: 0, timed_out: false, output_tail: output}} ->
          {:ok, output}

        {:ok, %ProcResult{timed_out: true, output_tail: output}} ->
          {:error, :keychain_timeout, output}

        {:ok, %ProcResult{output_tail: output}} ->
          {:error, :keychain_unavailable, output}

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, :keychain_unavailable, ""}
    end
  end

  defp decode(output) do
    case Base.decode64(String.trim(output)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :keychain_unavailable}
    end
  end

  defp account(label), do: "chatgpt:" <> label
end
