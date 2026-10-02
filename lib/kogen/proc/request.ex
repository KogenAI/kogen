defmodule Kogen.Proc.Request do
  @moduledoc false

  @enforce_keys [:argv, :cd, :env, :timeout_ms, :log_path, :stdin]
  defstruct [:argv, :cd, :env, :timeout_ms, :log_path, :stdin]

  @type stdin :: :null | {:binary, binary()} | {:file, Path.t()}
  @type t :: %__MODULE__{
          argv: [String.t()],
          cd: Path.t(),
          env: %{String.t() => String.t()},
          timeout_ms: non_neg_integer(),
          log_path: Path.t() | nil,
          stdin: stdin()
        }

  @known_options [:cd, :env, :timeout_ms, :log_path, :stdin]
  @runtime_keys [
    "ROOTDIR",
    "BINDIR",
    "EMU",
    "PROGNAME",
    "ESCRIPT",
    "ESCRIPT_DIR",
    "KOGEN_ERTS_DIR",
    "KOGEN_ERTS_BIN",
    "KOGEN_ESCRIPT_DIR",
    "KOGEN_BIN_DIR"
  ]
  @default_path "/usr/bin:/bin"
  @path_separator ":"

  @spec new(term(), term()) :: {:ok, t()} | {:error, atom()}
  def new(argv, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, cd} <- required_directory(opts),
         {:ok, argv} <- validate_argv(argv),
         {:ok, env} <- validate_env(Keyword.get(opts, :env, %{}), cd),
         {:ok, timeout_ms} <- validate_timeout(Keyword.get(opts, :timeout_ms, 120_000)),
         {:ok, log_path} <- validate_log_path(Keyword.get(opts, :log_path), cd),
         {:ok, stdin} <- validate_stdin(Keyword.get(opts, :stdin)) do
      {:ok,
       %__MODULE__{
         argv: argv,
         cd: cd,
         env: env,
         timeout_ms: timeout_ms,
         log_path: log_path,
         stdin: stdin
       }}
    end
  end

  def new(_argv, _opts), do: {:error, :invalid_options}

  @spec validate_options(keyword()) :: :ok | {:error, :invalid_options}
  defp validate_options(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and Enum.all?(keys, &(&1 in @known_options)) and
         length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  @spec required_directory(keyword()) :: {:ok, Path.t()} | {:error, atom()}
  defp required_directory(opts) do
    case Keyword.fetch(opts, :cd) do
      {:ok, path} when is_binary(path) ->
        if Path.type(path) == :absolute and File.dir?(path) do
          {:ok, Path.expand(path, "/")}
        else
          {:error, :invalid_cd}
        end

      _ ->
        {:error, :missing_cd}
    end
  end

  @spec validate_argv(term()) :: {:ok, [String.t()]} | {:error, atom()}
  defp validate_argv([executable | args] = argv) when is_binary(executable) do
    if executable != "" and
         Enum.all?(argv, &(is_binary(&1) and not String.contains?(&1, <<0>>))) do
      {:ok, [executable | args]}
    else
      {:error, :invalid_argv}
    end
  end

  defp validate_argv(_argv), do: {:error, :invalid_argv}

  @spec validate_env(term(), Path.t()) :: {:ok, map()} | {:error, atom()}
  defp validate_env(env, cd) when is_map(env) do
    if Enum.all?(env, &valid_env_entry?/1) do
      {:ok, child_env(env, cd)}
    else
      {:error, :invalid_env}
    end
  end

  defp validate_env(_env, _cd), do: {:error, :invalid_env}

  @spec valid_env_entry?(term()) :: boolean()
  defp valid_env_entry?({key, value}) when is_binary(key) and is_binary(value) do
    key != "" and not String.contains?(key, ["=", <<0>>]) and
      not String.contains?(value, <<0>>)
  end

  defp valid_env_entry?(_entry), do: false

  @spec child_env(map(), Path.t()) :: map()
  defp child_env(env, cd) do
    roots = runtime_roots(env, cd)
    env = Map.drop(env, @runtime_keys)
    env = Map.put_new(env, "PATH", @default_path)

    case Map.fetch(env, "PATH") do
      {:ok, path} -> Map.put(env, "PATH", strip_runtime_path(path, roots, cd))
      :error -> env
    end
  end

  @spec runtime_roots(map(), Path.t()) :: [Path.t()]
  defp runtime_roots(env, cd) do
    env
    |> Map.take(@runtime_keys)
    |> Enum.flat_map(fn {key, value} -> runtime_root(key, value, cd) end)
    |> Enum.uniq()
  end

  @spec runtime_root(String.t(), String.t(), Path.t()) :: [Path.t()]
  defp runtime_root("ESCRIPT", value, cd), do: [Path.dirname(Path.expand(value, cd))]
  defp runtime_root(_key, value, cd), do: [Path.expand(value, cd)]

  @spec strip_runtime_path(String.t(), [Path.t()], Path.t()) :: String.t()
  defp strip_runtime_path(path, roots, cd) do
    path
    |> String.split(@path_separator)
    |> Enum.reject(fn entry -> Enum.any?(roots, &runtime_path?(entry, &1, cd)) end)
    |> Enum.join(@path_separator)
  end

  @spec runtime_path?(String.t(), Path.t(), Path.t()) :: boolean()
  defp runtime_path?(entry, root, cd) do
    expanded = Path.expand(entry, cd)
    expanded == root or root == "/" or String.starts_with?(expanded, root <> "/")
  end

  @spec validate_timeout(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_timeout}
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: {:ok, timeout}
  defp validate_timeout(_timeout), do: {:error, :invalid_timeout}

  @spec validate_log_path(term(), Path.t()) :: {:ok, Path.t() | nil} | {:error, atom()}
  defp validate_log_path(nil, _cd), do: {:ok, nil}

  defp validate_log_path(path, _cd) when is_binary(path) do
    if Path.type(path) == :absolute and not String.contains?(path, <<0>>) do
      {:ok, Path.expand(path, "/")}
    else
      {:error, :invalid_log_path}
    end
  end

  defp validate_log_path(_path, _cd), do: {:error, :invalid_log_path}

  @spec validate_stdin(term()) :: {:ok, stdin()} | {:error, :invalid_stdin}
  defp validate_stdin(nil), do: {:ok, :null}

  defp validate_stdin({:binary, data}) do
    {:ok, {:binary, IO.iodata_to_binary(data)}}
  rescue
    ArgumentError -> {:error, :invalid_stdin}
  end

  defp validate_stdin({:file, path}) when is_binary(path) do
    if Path.type(path) == :absolute and not String.contains?(path, <<0>>) do
      {:ok, {:file, Path.expand(path, "/")}}
    else
      {:error, :invalid_stdin}
    end
  end

  defp validate_stdin(_stdin), do: {:error, :invalid_stdin}
end
