# cc_precompiler

A build tool for Elixir/OTP projects that provides native C/C++ code compilation support with a focus on build configuration and portable compilation across platforms.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:cc_precompiler, "~> 0.1.11"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

### Basic Usage

cc_precompiler integrates with your Mix build system to compile C/C++ code:

```elixir
# In mix.exs
def project do
  [
    app: :my_app,
    version: "0.1.0",
    elixir: "~> 1.14",
    compilers: [:cc_precompiler] ++ Mix.compilers(),
    deps: deps()
  ]
end
```

Add C/C++ source files to a `c_src/` directory in your project root:

```
my_app/
  c_src/
    my_native.c
    my_native.h
  lib/
  mix.exs
```

## Core Concepts

### Compilation Pipeline

cc_precompiler extends Mix's compiler chain to:

1. Detect C/C++ source files in `c_src/`
2. Apply preprocessing (e.g., variable substitution)
3. Invoke the native C compiler (gcc, clang)
4. Link compiled objects into priv/ or specified output directory
5. Integrate results into the Elixir application

### Source Organization

- **c_src/** - C/C++ source and header files
- **priv/** - Compiled native libraries and resources (loaded at runtime)
- **generated/** - Preprocessed C files (git-ignored)

### Preprocessing

Variables in C source can be expanded from mix.exs configuration:

```c
// c_src/config.h
#define APP_VERSION "{{ app_version }}"
```

Reference these in mix.exs:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    cc_precompiler: [
      app_version: "0.1.0"
    ]
  ]
end
```

## Configuration

### Project Configuration

Add cc_precompiler settings to your `mix.exs` project block:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    compilers: [:cc_precompiler] ++ Mix.compilers(),
    cc_precompiler: [
      # Path to C source directory (relative to project root)
      c_src_dir: "c_src",

      # Output directory for compiled objects
      output_dir: "priv",

      # Compiler flags
      compiler_flags: ["-O2", "-Wall"],

      # Linker flags
      linker_flags: [],

      # Include directories
      include_dirs: ["c_src"],

      # Variables available to preprocessor
      vars: []
    ]
  ]
end
```

### Environment-Specific Configuration

Use Mix.env() to customize compilation per environment:

```elixir
def project do
  config = [
    app: :my_app,
    compilers: [:cc_precompiler] ++ Mix.compilers()
  ]

  case Mix.env() do
    :dev ->
      Keyword.put(config, :cc_precompiler, [
        compiler_flags: ["-g", "-O0", "-Wall"]
      ])
    :prod ->
      Keyword.put(config, :cc_precompiler, [
        compiler_flags: ["-O3", "-Wall"]
      ])
    _ -> config
  end
end
```

### Compiler Selection

The default compiler is detected from the system. Override with:

```elixir
cc_precompiler: [
  cc: "/usr/bin/gcc",
  cxx: "/usr/bin/g++"
]
```

## Best Practices

### Header File Management

Keep headers in `c_src/` and include them properly:

```c
#include "my_header.h"
#include <stdlib.h>
```

Avoid absolute paths; use relative includes from c_src/.

### Conditional Compilation

Use preprocessor directives for platform-specific code:

```c
#ifdef __APPLE__
  // macOS-specific code
#elif defined(__linux__)
  // Linux-specific code
#endif
```

### Build Performance

- Place frequently-changed files last in compilation order
- Use incremental compilation: cc_precompiler tracks file timestamps
- Avoid unnecessary includes to reduce rebuild time

### Debugging

Enable debug symbols in development:

```elixir
cc_precompiler: [
  compiler_flags: if(Mix.env() == :dev, do: ["-g", "-O0"], else: ["-O3"])
]
```

Compiled objects are stored in `priv/`, inspect with `objdump` or similar tools.

### Linking Native Code

If your C code creates shared libraries, ensure they're placed in `priv/`:

```c
// In c_src/Makefile or build script
gcc -shared -fPIC mylib.c -o ../priv/mylib.so
```

Load in Elixir:

```elixir
defmodule MyApp.Native do
  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:my_app), "mylib")
    :erlang.load_nif(path, 0)
  end
end
```

### Cross-Compilation

When targeting different architectures, adjust compiler and flags:

```elixir
cc_precompiler: [
  cc: "arm-linux-gnueabihf-gcc",
  compiler_flags: ["--sysroot=/path/to/sysroot", "-O2"]
]
```

### Troubleshooting

**Issue: Compiler not found**

- Ensure gcc/clang is installed and in PATH
- Explicitly set `:cc` and `:cxx` in config if system detection fails

**Issue: Header files not found**

- Add directory to `:include_dirs` config
- Check relative paths in #include statements

**Issue: Linking errors**

- Verify `:linker_flags` reference available libraries
- Check library search paths with `-L` flag

---

**Version:** 0.1.11
**Source:** https://github.com/cc_precompiler/cc_precompiler
**Generated:** 2026-06-17
