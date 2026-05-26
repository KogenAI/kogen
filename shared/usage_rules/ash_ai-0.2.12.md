# ash_ai

Elixir library that integrates AI capabilities with the Ash framework, enabling applications to expose actions as tools for language models and build LLM-powered features like chatbots and agentic systems.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:ash_ai, "~> 0.2"}
```

Or use Igniter:

```bash
mix igniter.install ash_ai
```

### Basic Tool Definition

Define tools in your Ash domain to expose actions to AI agents:

```elixir
defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshAi]

  tools do
    tool :read_posts, MyApp.Blog.Post, :read
    tool :create_post, MyApp.Blog.Post, :create
  end
end
```

## Core Concepts

### Tool Definition & Data Access

**Tool Creation**: Expose Ash actions as callable tools for LLMs

- **Filtering/Sorting**: Only public attributes accessible
- **Arguments**: Public action arguments exposed
- **Responses**: Public attributes returned by default
- **Relationships**: Use `load` option to include related data

```elixir
tool :list_users, MyApp.Accounts.User, :read, load: [:posts, :comments]
```

### Prompt-Backed Actions

Delegate action implementation to LLMs with structured outputs:

```elixir
action :analyze_sentiment, :atom do
  argument :text, :string
  run prompt(ChatOpenAI.new!(%{model: "gpt-4o"}), tools: true)
end
```

LLM processes arguments and returns structured data matching action result type.

### Tool Execution Callbacks

Monitor real-time tool execution during LLM interactions:

```elixir
AshAi.setup_ash_ai(chain,
  on_tool_start: fn event ->
    IO.puts("Starting #{event.tool_name}...")
  end,
  on_tool_end: fn event ->
    IO.puts("Completed #{event.tool_name}")
  end
)
```

## Configuration

### Environment Setup

Required for LLM integration:

```bash
export OPENAI_API_KEY="your-key"
```

Configure LangChain models in `config.exs`:

```elixir
config :my_app, ChatOpenAI, api_key: System.get_env("OPENAI_API_KEY")
```

### MCP Server Setup

**Development**: Add plug to Phoenix endpoint

```elixir
plug AshAi.Mcp.Dev  # Available at /ash_ai/mcp
```

**Production**: Pre-built server implements protocol version 2025-03-26

**Authentication**: Protect MCP endpoint with API key authentication

```elixir
pipeline :mcp do
  plug AshAuthentication.Strategy.ApiKey.Plug,
    resource: YourApp.Accounts.User,
    required?: false
end
```

### Chat Generation

Generate chat UI scaffolding:

```bash
mix ash_ai.gen.chat --live
```

Requirements:

- User resource configured
- Tailwind and DaisyUI included
- Ash Oban for async jobs
- Ash Postgres for storage

Access UI at `/chat`

## Best Practices

### Data Access Control

Use public/private attributes to control LLM access:

```elixir
attribute :email, :string, public?: false      # Hidden from LLM
attribute :name, :string, public?: true        # Visible to LLM
```

Private attributes prevent unintended data exposure in tool outputs.

### Tool Scope Management

Define focused, specific tools rather than generic ones:

```elixir
# Good: Specific action with clear intent
tool :search_posts_by_author, MyApp.Blog.Post, :read

# Avoid: Generic action with complex filtering
tool :generic_read, MyApp.Blog.Post, :read
```

### Vector Search Strategy

Choose embedding update strategy based on use case:

- **`:after_action`** (default): Sync updates, simple setup, slight latency
- **`:ash_oban`**: Async queue, better performance, requires Oban
- **`:manual`**: On-demand generation, maximum control

```elixir
vector_search :search_content,
  action: :read,
  strategy: :ash_oban,
  on: :content
```

### LLM Model Selection

Use appropriate models for complexity:

- `gpt-4o`: Complex reasoning, multi-tool workflows
- `gpt-4-turbo`: Balanced performance/cost, tool calling
- `gpt-3.5-turbo`: Simple tasks, cost-sensitive

### Error Handling

Wrap LLM calls to gracefully handle failures:

```elixir
case AshAi.run_with_tools(actor, domain, prompt) do
  {:ok, result} -> result
  {:error, reason} -> handle_error(reason)
end
```

### Tool Testing

Test tools independently before LLM integration:

```elixir
MyApp.Blog.Post.read()
|> Ash.Query.limit(10)
|> Ash.read!()
```

Verify LLM tool schema matches action definition.

---

**Version:** 0.2.12
**Source:** [hexdocs.pm/ash_ai](https://hexdocs.pm/ash_ai/)
**Generated:** 2025-10-28
