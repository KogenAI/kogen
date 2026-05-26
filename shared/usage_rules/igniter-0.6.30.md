# igniter

Igniter is a code generation and project patching framework for Elixir. It provides a structured pipeline for modifying projects programmatically, enabling intelligent automation of code changes without wrestling low-level file system details.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:igniter, "~> 0.6", only: [:dev, :test]}
  ]
end
```

Or install globally as an archive:

```bash
mix archive.install hex igniter_new
```

### Basic Usage

```bash
# Install new library with automatic setup
mix igniter.install phoenix

# Upgrade dependencies with codemods
mix igniter.upgrade

# Run refactoring tasks
mix igniter.refactor.rename_function
```

## Core Concepts

### The Igniter Struct

At its heart, Igniter operates through an **Igniter struct** that accumulates modifications throughout execution. Rather than immediately writing changes, the tool collects all operations and applies them together at the end. This transactional approach prevents partial writes if an error occurs.

### Key Features

**File Operations**

- Create new files
- Update existing code
- Copy templates
- Delete files
- Manage directories

**Code Transformation**

- Zipper-based AST modifications using `Sourceror` library
- Precise Elixir code transformations
- Safe pattern matching on code structure

**Task Composition**

- Compose multiple mix tasks together
- One task can orchestrate others
- Safe argument passing between tasks
- Reusable generator components

**State Management**

- Use assigns to store arbitrary data between operations
- Pass information between composed tasks
- Maintain context throughout execution

**Feedback Mechanisms**

- Issues (blocking - prevent successful execution)
- Warnings (non-blocking - inform user of potential problems)
- Notices (informational messages)

## Configuration

### Special Assigns

Control Igniter behavior through special assigns:

**`:prompt_on_git_changes?`**

- Warns users about uncommitted changes before applying modifications
- Prevents accidental loss of work
- Default behavior recommended for production use

**`:quiet_on_no_changes?`**

- Suppresses "no changes made" messaging
- Useful for conditional generators that may not always apply

### Creating Custom Tasks

```elixir
defmodule Mix.Tasks.Igniter.Gen.Custom do
  use Mix.Task
  use Igniter.Mix.Task

  def igniter(igniter, _args) do
    igniter
    |> Igniter.Project.create_file("lib/my_file.ex", "content")
    |> Igniter.Project.update_file("mix.exs", &update_deps/1)
  end
end
```

## Best Practices

**Use Installers for Libraries**

- Library authors should build installers that automatically integrate dependencies
- One-command setup reduces friction for users
- Installers should be composable with other tasks

**Leverage Upgraders for Semantic Updates**

- Apply version-specific transformations automatically
- Combine dependency updates with code codemods
- Guide users through breaking changes

**Composition Over Duplication**

- Mix tasks built with Igniter are individually callable and composable
- Reuse existing tasks rather than reimplementing functionality
- Share common patterns across generators

**Safe Code Modification**

- Use zipper-based transformations for AST modifications
- Let the framework handle file I/O and error handling
- Accumulate changes before applying them

**User Communication**

- Add issues for blocking problems (prevent execution)
- Use warnings for non-blocking concerns
- Include notices to explain what's happening
- Let users verify changes before application

**Library Author Pattern**

- Add Igniter with `optional: true` to prevent production dependencies
- Support both direct installation and composable task patterns
- Document any custom installers or upgraders provided

**Version Handling**

- Note: Users on versions prior to 0.3.78 must manually update dependencies before running upgrade tasks
- Plan for smooth upgrade paths in your generators
- Test with multiple versions when building libraries

---

**Version:** 0.6.30
**Source:** [hexdocs.pm/igniter](https://hexdocs.pm/igniter/)
**Generated:** 2025-10-28
