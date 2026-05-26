# elixir_make

Elixir Make is a compilation task that integrates `make` command execution into Elixir projects, enabling seamless cross-platform C/C++ compilation, artifact generation, and precompiled binary distribution.

## Quick Start

Add to `mix.exs`:

```elixir
def project do
  [
    app: :my_app,
    compilers: [:elixir_make] ++ Mix.compilers(),
    make_targets: ["all"],
    make_clean: ["clean"]
  ]
end

def deps do
  [
    {:elixir_make, "~> 0.9.0"}
  ]
end
```

Run `mix compile` to execute `make`. The task streams output in real-time and fails if `make` exits with a non-zero status.

## Core Concepts

**Compilation Task**: `mix compile.elixir_make` runs during the standard Elixir compilation cycle, supporting multiple targets and cleaning.

**Platform Detection**: Automatically selects the correct `make` executable — `gmake` on FreeBSD, `nmake` on Windows, `make` everywhere else.

**Output Handling**: All output is streamed to stdout; subprocess failures immediately propagate as compilation errors.

**Environment Injection**: Automatically provides `MIX_ENV`, `MIX_BUILD_PATH`, `ERTS_INCLUDE_DIR`, and other Erlang-related variables to the make process.

## Configuration

**`:make_executable`** — Which `make` program to invoke. Defaults based on OS detection.

**`:make_makefile`** — Path to the Makefile (defaults to `Makefile` in the project root).

**`:make_targets`** — List of targets to run. If empty, make executes the first default target.

**`:make_clean`** — List of targets to run during `mix clean`.

**`:make_cwd`** — Working directory for make, relative to project root (defaults to root).

**`:make_env`** — Extra environment variables as a map or anonymous function returning a map. Applied after defaults; allows overrides.

**`:make_args`** — Additional command-line arguments passed to the make invocation.

**`:make_error_message`** — Custom error message displayed if the task fails.

**`:make_precompiler`** — Tuple `{:nif, ModuleName}` or `{:port, ModuleName}` to enable precompiled artifact distribution. Requires `:make_precompiler_url`.

**`:make_precompiler_url`** — Download URL template for precompiled artifacts (e.g., `"https://example.com/downloads/{filename}"`).

**`:make_precompiler_filename`** — Output filename for the artifact.

**`:make_precompiler_downloader`** — Custom module implementing artifact download logic.

## Best Practices

**Artifact Layout**: Never commit the `priv/` directory to source control. Generate it via the Makefile during compilation. Use environment variables like `$MIX_APP_PATH/priv` to copy built artifacts to the correct location.

**Environment Variables**: Don't hardcode paths. Reference `MIX_BUILD_PATH`, `ERTS_INCLUDE_DIR`, and `MIX_ENV` to ensure portability across development, testing, and production builds.

**Make Targets**: Define separate targets for build and cleanup. Use `:make_targets: ["all"]` for building and `:make_clean: ["clean"]` for cleanup.

**Cross-Platform Makefiles**: Use platform-agnostic make syntax or separate platform-specific Makefiles with conditional includes. Test on all target platforms.

**Precompilation Distribution**: When distributing binaries, always specify a download URL and handler. This allows users to skip compilation if prebuilt artifacts are available.

**Error Handling**: Use `:make_error_message` to provide actionable troubleshooting guidance when compilation fails (e.g., "Install GCC and run `make clean` before retrying").

**Environment Functions**: Use `:make_env` as a function when environment values depend on runtime state:

```elixir
make_env: fn ->
  %{
    "CUSTOM_FLAG" => System.get_env("MY_FLAG", "default")
  }
end
```

---

**Version:** 0.9.0  
**Source:** [hexdocs.pm/elixir_make](https://hexdocs.pm/elixir_make/)  
**Generated:** 2026-04-25
