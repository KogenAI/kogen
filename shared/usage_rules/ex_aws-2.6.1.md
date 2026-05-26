# ex_aws

ExAws is a flexible, lightweight Elixir library for interacting with AWS services. It emphasizes minimal dependencies, allowing developers to select their preferred JSON codecs and HTTP clients.

## Quick Start

### Installation

Add ex_aws and service-specific packages to `mix.exs`:

```elixir
defp deps do
  [
    {:ex_aws, "~> 2.6"},
    {:ex_aws_s3, "~> 2.0"},      # for S3
    {:hackney, "~> 1.9"},         # HTTP client
    {:sweet_xml, "~> 0.6"},       # XML parsing
    {:jason, "~> 1.1"}            # JSON codec (optional)
  ]
end
```

### Basic Usage

```elixir
# List S3 objects
ExAws.S3.list_objects("my-bucket") |> ExAws.request()

# With explicit region
ExAws.S3.list_objects("my-bucket") |> ExAws.request(region: "us-west-1")

# Streaming large result sets
ExAws.S3.list_objects("my-bucket") |> ExAws.stream!() |> Enum.to_list()
```

## Core Concepts

### Request Pattern

ExAws uses a builder pattern: operations return a struct, then `.request()` or `.stream!()` executes the operation.

- **ExAws.request/1,2** — Execute a single request; returns `{:ok, response}` or `{:error, reason}`
- **ExAws.stream!/1,2** — Returns a lazy stream for paginated results; useful for large datasets

### Credential Resolution

The library resolves AWS credentials automatically in this order:

1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
2. EKS Pod Identity (within EKS clusters)
3. EC2 instance role (running on EC2)

No explicit credential passing required in most deployments.

### Service Packages

Core `ex_aws` provides operation builders. Service-specific packages (e.g., `ex_aws_s3`, `ex_aws_dynamodb`) contain service definitions:

- `ex_aws_s3` — Simple Storage Service
- `ex_aws_dynamodb` — DynamoDB
- `ex_aws_lambda` — Lambda
- `ex_aws_sns` — Simple Notification Service
- `ex_aws_sqs` — Simple Queue Service

## Configuration

### Region

```elixir
# config/config.exs
config :ex_aws,
  region: "us-west-2"
```

Or override per-request:

```elixir
ExAws.S3.list_objects("bucket") |> ExAws.request(region: "eu-west-1")
```

### HTTP Client Options

Configure Hackney (or your chosen HTTP client) options globally:

```elixir
config :ex_aws, :hackney_opts,
  follow_redirect: true,
  recv_timeout: 30_000,
  connect_timeout: 10_000
```

### JSON Codec

By default, ExAws uses JSON parsers from available packages. Explicitly configure:

```elixir
config :ex_aws,
  json_codec: Jason  # or Poison, jsx, etc.
```

## Best Practices

### 1. Error Handling

Always handle request results:

```elixir
case ExAws.S3.get_object("bucket", "key") |> ExAws.request() do
  {:ok, response} -> process(response)
  {:error, reason} -> Logger.error("AWS error: #{inspect(reason)}")
end
```

### 2. Streaming for Large Datasets

Use `stream!()` for operations returning many results; avoids loading entire result set into memory:

```elixir
ExAws.S3.list_objects("bucket")
|> ExAws.stream!()
|> Stream.take(1000)
|> Enum.to_list()
```

### 3. Retry Strategy

ExAws implements automatic exponential backoff with Full Jitter. Trust the library's retry logic; do not manually retry in application code.

### 4. Credential Security

- Use IAM roles in production (EC2, EKS, Lambda) instead of long-lived keys
- Rotate temporary credentials regularly
- Never commit AWS keys to version control; use environment variables or credential providers

### 5. Timeout Configuration

Set appropriate timeouts for your use case:

```elixir
config :ex_aws, :hackney_opts,
  recv_timeout: 30_000,        # response timeout
  connect_timeout: 10_000      # connection timeout
```

Long operations (e.g., large S3 uploads) may need higher timeouts.

### 6. Region Consistency

Specify region consistently across operations in a service. Mixing regions complicates debugging:

```elixir
# Good: explicit region in config
config :ex_aws, region: "us-east-1"

# Also good: request-level override when needed
ExAws.S3.get_object("bucket", "key") |> ExAws.request(region: "us-west-2")
```

### 7. Dependency Injection

For testing, inject HTTP client and credential functions:

```elixir
ExAws.request(operation, http_client: MyMockClient, credentials_provider: MyMockProvider)
```

---

**Version:** 2.6.1  
**Source:** [hexdocs.pm/ex_aws](https://hexdocs.pm/ex_aws/)  
**Generated:** 2026-04-25
