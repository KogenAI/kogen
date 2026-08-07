# elixir_make

Elixir Make is a Mix compiler that integrates Makefiles into Elixir projects, enabling seamless invocation of make commands during the build process. It abstracts platform-specific build tools and provides a clean integration point for native code compilation.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [{:elixir_make, "~> 0.10", runtime: false}]
end
```

### Enable the Compiler

Update your `mix.exs` project configuration:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    compilers: [:elixir_make] ++ Mix.compilers,
    # ... other config
  ]
end
```

### Add a Makefile

Create a `Makefile` at your project root (or `Makefile.win` for Windows). The compiler will automatically detect and execute it.

## Core Concepts

### Platform-Specific Tool Selection

The compiler automatically selects the appropriate build tool based on the operating system:

- **Unix/Linux/macOS**: `make`
- **Windows**: `nmake`
- **FreeBSD/OpenBSD**: `gmake`

### Build Directory Structure

Place your Makefile at the project root. Source files are typically organized as:

```
project/
├── Makefile
├── Makefile.win
├── mix.exs
├── src/
│   ├── file.c
│   ├── file.h
│   └── ...
├── lib/
└── test/
```

### Compilation Integration

The `:elixir_make` compiler runs as part of the standard Mix compile flow, appearing in your compilation sequence before or after other compilers depending on configuration order.

## Configuration

### Basic Configuration

```elixir
compilers: [:elixir_make] ++ Mix.compilers
```

Place this before other compilers if native code must compile before Elixir code that depends on it.

### Makefile Targets

By default, the compiler invokes `make` without arguments. Customize via `make_cwd` or `make_targets` in your environment or Mix configuration.

### Publishing with Native Code

When publishing to Hex.pm, include all source files in the `files` option:

```elixir
def project do
  [
    # ... other config
    files: ["lib", "LICENSE", "mix.exs", "README.md", "src/*.[ch]", "Makefile", "Makefile.win"]
  ]
end
```

This ensures your Makefiles and source code are available to users who install your package.

## Best Practices

### Minimize Native Dependencies

Use Elixir and Erlang/OTP capabilities first. Reserve native code for performance-critical paths or essential system interaction that cannot be achieved through NIFs or ports.

### Clean Build Handling

Ensure your Makefile includes proper `clean` targets to prevent stale artifacts:

```makefile
.PHONY: clean
clean:
	rm -f $(OBJ_FILES) $(TARGET)
```

### Cross-Platform Compatibility

Test your Makefile on both Unix and Windows (or use appropriate conditional logic in your Makefile):

```makefile
ifdef ComSpec
    # Windows-specific commands
else
    # Unix-specific commands
endif
```

### Documentation

Document your native code build process in your README, including:

- Required build tools (gcc, make, nmake)
- Platform-specific build instructions
- Known limitations or compatibility notes

### Dependency Management

Clearly specify required system dependencies in your mix.exs or README. Users need to know what build tools must be installed before compilation can succeed.

### Error Handling

Test build failures gracefully. Ensure your Makefile produces clear error messages that help users diagnose missing dependencies or configuration issues.

---

**Version:** 0.10.0  
**Source:** [github.com/elixir-lang/elixir_make](https://github.com/elixir-lang/elixir_make)  
**Generated:** 2026-08-07
