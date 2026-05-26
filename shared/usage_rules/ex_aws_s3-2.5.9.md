# ex_aws_s3

ExAws.S3 provides Elixir developers with a comprehensive interface to interact with Amazon S3 buckets and objects. It supports both simple and high-level operations, streaming for large files, and full bucket/object management capabilities.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:ex_aws, "~> 2.0"},
    {:ex_aws_s3, "~> 2.0"},
    {:poison, "~> 3.0"},
    {:hackney, "~> 1.9"},
    {:sweet_xml, "~> 0.6.6"}  # optional, for XML parsing
  ]
end
```

### Basic Operations

Simple operations use `ExAws.request!()`:

```elixir
S3.list_objects("my-bucket") |> ExAws.request!()
S3.put_object("my-bucket", "path/to/file", contents) |> ExAws.request!()
S3.get_object("my-bucket", "object.txt") |> ExAws.request!()
S3.delete_object("my-bucket", "object.txt") |> ExAws.request!()
```

High-level operations with streaming:

```elixir
"path/to/large/file"
|> S3.Upload.stream_file()
|> S3.upload("my-bucket", "destination/path")
|> ExAws.request()
```

## Core Concepts

### Operation Categories

**Bucket Operations:** Creation, deletion, ACL, CORS, lifecycle, logging, versioning, tagging, website hosting, and policy configuration.

**Object Operations:** Upload, download, copy, delete, metadata management, ACL control, and multipart upload for large files.

**Utility Operations:** Presigned URLs, POST requests, object restoration, and CORS configuration.

### Streaming

Use `ExAws.stream!()` to paginate through large result sets without loading everything into memory:

```elixir
S3.list_objects("my-bucket", prefix: "some/prefix")
|> ExAws.stream!()
|> Enum.to_list()
```

Streaming is automatic for operations that return multiple pages. Specify `max_keys` to control page size.

### Two-Level Design

Simple operations: return Elixir structs representing AWS responses.
High-level operations: handle complex flows like multipart uploads with resumable support and progress tracking.

## Configuration

### Endpoint Customization

For local development with MinIO or custom endpoints:

```elixir
config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 9000
```

### Hash Algorithm

```elixir
config :ex_aws_s3, :content_hash_algorithm, :sha256
```

Options: `:md5`, `:sha256`, `:sha`. Default is `:sha256`.

### AWS Credentials

Configure credentials via environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) or explicit config:

```elixir
config :ex_aws,
  access_key_id: "YOUR_KEY",
  secret_access_key: "YOUR_SECRET",
  region: "us-east-1"
```

### Custom Headers

Pass metadata as options to operations:

```elixir
S3.put_object("bucket", "key", data,
  content_type: "application/json",
  metadata: %{"custom-key" => "value"}
)
```

## Best Practices

### Multipart Uploads for Large Files

Use `S3.Upload.stream_file()` for files larger than a few MB. Enables concurrent chunk upload and resume capability:

```elixir
S3.Upload.stream_file("large_file.zip", chunk_size: 5_242_880)
|> S3.upload("bucket", "destination/path")
|> ExAws.request()
```

### Concurrent Operations

Leverage `Task.async_stream/5` for batch operations:

```elixir
paths
|> Task.async_stream(fn path ->
  S3.put_object("bucket", path, File.read!(path)) |> ExAws.request()
end, max_concurrency: 10)
|> Stream.run()
```

### Presigned URLs

Generate temporary signed URLs without sharing credentials:

```elixir
ExAws.Config.new(:s3)
|> S3.presigned_url(:get, "bucket", "object.txt", expires_in: 3600)
|> elem(0)  # returns {url, headers}
```

Supports `:get`, `:put`, `:delete`, and `:post` methods.

### Memory Efficiency

For downloading large files, stream to disk instead of memory:

```elixir
S3.download_file("my-bucket", "path/on/s3", "local/path")
|> ExAws.request()
```

Or use destination: `:memory` for streaming to memory when needed.

### Bucket Lifecycle Management

Configure retention and transitions:

```elixir
S3.put_bucket_lifecycle("bucket", expiration_days: 90,
  transitions: [storage_class: "GLACIER", days: 30])
|> ExAws.request()
```

### List Filtering and Pagination

Always use pagination for large buckets:

```elixir
S3.list_objects("bucket", prefix: "dir/", max_keys: 100)
|> ExAws.stream!()
|> Enum.take(50)
```

### Object Tagging for Organization

Tag objects for lifecycle policies and cost allocation:

```elixir
S3.put_object_tagging("bucket", "object", %{
  "Environment" => "prod",
  "Application" => "myapp"
})
|> ExAws.request()
```

### Error Handling

Requests can fail for network, credentials, or S3 errors. Use pattern matching:

```elixir
case S3.get_object("bucket", "key") |> ExAws.request() do
  {:ok, %{body: data}} -> data
  {:error, {:http_error, 404, _}} -> :not_found
  {:error, reason} -> handle_error(reason)
end
```

---

**Version:** 2.5.9  
**Source:** [hexdocs.pm/ex_aws_s3](https://hexdocs.pm/ex_aws_s3/)  
**Generated:** 2026-04-25
