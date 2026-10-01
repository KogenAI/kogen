defmodule Kh.Tools.Write do
  @moduledoc false

  def spec do
    %{
      name: "write",
      description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file to write (relative or absolute)"},
          "content" => %{"type" => "string", "description" => "Content to write to the file"}
        },
        "required" => ["path", "content"]
      }
    }
  end

  def run(%{"path" => path, "content" => content}, ctx) when is_binary(path) and is_binary(content) do
    abs = Kh.Util.resolve(path, ctx.cwd)

    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, content) do
      {:ok, "Successfully wrote to #{path}"}
    else
      {:error, reason} -> {:error, "Could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  def run(_, _), do: {:error, "write requires string 'path' and 'content'"}
end
