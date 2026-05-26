# Recipe: External Python Tool Integration via System.cmd()

## Problem

Need to integrate existing Python libraries or tools from Elixir/Phoenix applications without rewriting functionality in Elixir. Common use cases include ML libraries, data processing tools, or specialized APIs that have better Python support.

## Solution

Use System.cmd() with JSON communication for structured data exchange between Elixir and Python processes. This approach provides clean separation, leverages existing Python ecosystems, and maintains type safety through structured data formats.

## Implementation

### 1. Python Script Structure

```python
#!/usr/bin/env python3
import json
import sys

def main_function(input_data):
    try:
        # Your Python logic here
        result = process_data(input_data)
        return {
            "success": True,
            "data": result,
            "metadata": {"processing_time": 0.5}
        }
    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "error_type": type(e).__name__
        }

if __name__ == "__main__":
    # Read input from command line arguments or stdin
    input_arg = sys.argv[1] if len(sys.argv) > 1 else None
    result = main_function(input_arg)
    print(json.dumps(result))
```

### 2. Elixir Integration Module

```elixir
defmodule MyApp.PythonBridge do
  @moduledoc """
  Integration with Python scripts via System.cmd() and JSON communication.
  """

  require Logger

  @python_script_path Path.join([Application.app_dir(:my_app), "priv", "python", "script.py"])
  @default_timeout 30_000

  def call_python_script(input_data, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    python_path = get_python_path()

    with {:ok, json_input} <- Jason.encode(input_data),
         {output, 0} <- System.cmd(python_path, [@python_script_path, json_input],
                                  stderr_to_stdout: true, timeout: timeout),
         {:ok, result} <- Jason.decode(output) do
      case result do
        %{"success" => true, "data" => data} ->
          {:ok, data}
        %{"success" => false, "error" => error} ->
          {:error, error}
        _ ->
          {:error, "Invalid response format"}
      end
    else
      {_output, exit_code} when exit_code > 0 ->
        Logger.error("Python script failed with exit code #{exit_code}")
        {:error, :script_execution_failed}

      {:error, :timeout} ->
        Logger.error("Python script timed out after #{timeout}ms")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Python integration error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_python_path do
    Application.get_env(:my_app, :python_path, "python3")
  end
end
```

### 3. Environment Setup

```bash
# priv/python/requirements.txt
numpy==1.24.0
pandas==2.0.0
# ... other dependencies
```

**Automated Setup with Mix Task:**

```elixir
# lib/mix/tasks/python.setup.ex
defmodule Mix.Tasks.Python.Setup do
  use Mix.Task
  @shortdoc "Sets up Python environment"

  def run(_args) do
    python_dir = Path.join([File.cwd!(), "priv", "python"])
    # Create venv, upgrade pip, install requirements
    # See full implementation in YouTube Academy project
  end
end

# In mix.exs aliases:
defp aliases do
  [
    setup: ["deps.get", "ecto.setup", "python.setup", "assets.build"]
    # ...
  ]
end
```

**Manual Setup (alternative):**

```bash
cd priv/python
python3 -m venv venv
source venv/bin/activate  # or venv\Scripts\activate on Windows
pip install -r requirements.txt
```

### 4. Configuration

```elixir
# config/runtime.exs
config :my_app,
  python_path: System.get_env("PYTHON_PATH", "python3")

# For virtual environment:
# PYTHON_PATH=/path/to/project/priv/python/venv/bin/python3
```

### 5. Error Handling Patterns

```elixir
def process_with_python(data) do
  case MyApp.PythonBridge.call_python_script(data, timeout: 60_000) do
    {:ok, result} ->
      {:ok, result}

    {:error, :timeout} ->
      {:error, "Processing took too long. Please try with smaller data."}

    {:error, :script_execution_failed} ->
      {:error, "Python environment error. Please check configuration."}

    {:error, reason} when is_binary(reason) ->
      {:error, "Processing failed: #{reason}"}

    {:error, _} ->
      {:error, "Unknown processing error. Please try again."}
  end
end
```

## Considerations

### When to Use

- Leveraging existing Python libraries (ML, data science, specialized APIs)
- Prototyping with familiar Python tools before Elixir implementation
- Processing that benefits from Python's ecosystem
- When rewriting in Elixir would be significantly more complex

### When NOT to Use

- Simple operations that can be easily done in Elixir
- High-frequency operations (overhead of process spawning)
- When you need streaming/bidirectional communication
- Real-time applications requiring sub-millisecond response times

### Performance Considerations

- Process spawning overhead (~10-50ms per call)
- JSON encoding/decoding overhead
- Python startup time (mitigate with virtual environment)
- Memory usage for large data payloads
- Consider connection pooling for high-volume scenarios

### Security Considerations

- Validate all inputs before passing to Python
- Use absolute paths for Python scripts
- Consider sandboxing for untrusted data
- Limit timeout values to prevent resource exhaustion
- Sanitize error messages before exposing to users

### Testing Patterns

```elixir
defmodule MyApp.PythonBridgeTest do
  use ExUnit.Case

  describe "call_python_script/2" do
    test "handles successful processing" do
      input = %{"data" => [1, 2, 3]}
      assert {:ok, _result} = MyApp.PythonBridge.call_python_script(input)
    end

    test "handles Python errors gracefully" do
      invalid_input = %{"invalid" => true}
      assert {:error, _reason} = MyApp.PythonBridge.call_python_script(invalid_input)
    end

    test "respects timeout settings" do
      input = %{"sleep" => 10}  # Causes Python script to sleep
      assert {:error, :timeout} = MyApp.PythonBridge.call_python_script(input, timeout: 1000)
    end
  end
end
```

## Example Usage

From the YouTube Academy PoC, integrating youtube-transcript-api:

```elixir
# lib/youtube_academy/transcript.ex
defmodule YoutubeAcademy.Transcript do
  alias YoutubeAcademy.PythonBridge

  def extract_transcript(video_id) do
    case PythonBridge.call_python_script(video_id, timeout: 30_000) do
      {:ok, %{"transcript" => text, "duration" => duration}} ->
        {:ok, %{text: text, duration: duration}}

      {:error, reason} ->
        {:error, "Transcript extraction failed: #{reason}"}
    end
  end
end
```

## Related Recipes

- [Phoenix Async Feature Testing with LiveView](phoenix-async-feature-test-liveview.md) - For testing async operations
- [Phoenix Param Normalization](phoenix-param-normalization.md) - For input validation
