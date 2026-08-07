# exqlite

Exqlite is an Elixir library providing direct SQLite3 database access. It offers both high-level and low-level APIs for database operations, with support for extensions, encryption, and custom type handling. For Ecto-based applications, use the separate Ecto SQLite3 adapter instead.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
{:exqlite, "~> 0.39"}
```

### Basic Usage

Using `Exqlite.Basic` for simple operations:

```elixir
# Open a connection
{:ok, conn} = Exqlite.Basic.open("path/to/database.db")

# Create a table
Exqlite.Basic.exec(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

# Insert data with parameter binding
Exqlite.Basic.exec(conn, "INSERT INTO users (name) VALUES (?1)", ["Alice"])

# Query data
{:ok, statement} = Exqlite.Connection.prepare(conn, "SELECT * FROM users")
{:ok, rows} = Exqlite.Connection.execute(conn, statement, [])

# Close connection
Exqlite.Basic.close(conn)
```

## Core Concepts

### Connection Workflow

The core workflow involves three steps:

1. **Open** — Establish a database connection with `Exqlite.Basic.open(path)`
2. **Prepare** — Prepare SQL statements to prevent SQL injection and improve performance
3. **Execute & Step** — Run statements and iterate through results

### Prepared Statements

Exqlite uses prepared statements for all SQL execution:

```elixir
{:ok, conn} = Exqlite.Basic.open("db.db")
{:ok, statement} = Exqlite.Connection.prepare(conn, "SELECT * FROM users WHERE id = ?1")
{:ok, rows} = Exqlite.Connection.execute(conn, statement, [42])
```

**Important:** Prepared statements are not cached or immutable. Do not manipulate statements concurrently; this risks data corruption.

### Parameter Binding

Use `?1`, `?2`, etc. for positional parameters in prepared statements:

```elixir
Exqlite.Connection.execute(conn, statement, [value1, value2])
```

### Binary Data

Store binary data using the `{:blob, data}` format:

```elixir
Exqlite.Connection.execute(conn, statement, [{:blob, <<1, 2, 3>>}])
```

### Datetime Handling

SQLite stores datetime values without timezone information. Your application must manage timezone separately if needed:

```elixir
# Store: convert to UTC before inserting
utc_time = DateTime.utc_now()
# Retrieve: convert back from stored UTC string
```

### Module Structure

- **Exqlite.Connection** — DBProtocol implementation for database connections
- **Exqlite.Basic** — Simplified API for straightforward use cases
- **Exqlite.Sqlite3** — NIF (Native Implemented Function) interface for direct control
- **Exqlite.Query** — Prepared query representation
- **Exqlite.Result** — Query result handling
- **Exqlite.Error** — Error reporting and management

## Configuration

### Pragmas

Configure SQLite behavior via `Exqlite.Pragma` options during connection initialization. Common options:

**Performance & Storage:**

- `cache_size` — Size of SQLite page cache
- `cache_spill` — Cache spill size for query optimization
- `busy_timeout` — Milliseconds to wait before returning BUSY error
- `journal_mode` — Write-ahead logging mode (WAL recommended for concurrency)
- `synchronous` — Synchronization mode for durability vs. performance tradeoff

**Data Integrity:**

- `foreign_keys` — Enable foreign key constraint enforcement
- `secure_delete` — Securely overwrite deleted data
- `temp_store` — Storage location for temporary tables (MEMORY or FILE)

**Concurrency & Locking:**

- `locking_mode` — Lock behavior (NORMAL or EXCLUSIVE)
- `wal_auto_check_point` — Automatic WAL checkpoint frequency

**Behavior:**

- `auto_vacuum` — Automatic database file shrinking
- `case_sensitive_like` — Case sensitivity in LIKE operator

Example configuration:

```elixir
{:ok, conn} = Exqlite.Basic.open("db.db")
# Configure pragmas after opening
Exqlite.Connection.execute(conn, "PRAGMA journal_mode = WAL", [])
Exqlite.Connection.execute(conn, "PRAGMA foreign_keys = ON", [])
```

### Extensions

Load SQLite extensions at runtime:

```elixir
Exqlite.Basic.enable_load_extension(conn)
Exqlite.Basic.load_extension(conn, "path/to/extension.so")
Exqlite.Basic.disable_load_extension(conn)
```

### Database Encryption

Support for encryption through SQLCipher or SEE is available via compile-time configuration using environment variables. Consult the project repository for specialized encryption setup.

## Best Practices

### Connection Management

- Open a single connection per database in most cases
- Close connections explicitly with `Exqlite.Basic.close(conn)` to free resources
- Use connection pooling for multi-threaded applications (consider Poolboy or connection supervisors)

### Statement Reuse

- Prepare statements once and reuse them for multiple executions to improve performance
- Do not share prepared statements across processes without synchronization

### Concurrent Access

- SQLite does not support simultaneous database writes; queue writes or use file-level locking
- Multiple readers are safe; only one writer is allowed at a time
- WAL mode (`PRAGMA journal_mode = WAL`) improves concurrent read performance

### Error Handling

Use pattern matching on `{:ok, result}` and `{:error, reason}` tuples:

```elixir
case Exqlite.Connection.execute(conn, statement, []) do
  {:ok, rows} -> process_rows(rows)
  {:error, reason} -> Logger.error("Query failed: #{reason}")
end
```

### Type Safety

Define custom type extensions via `Exqlite.TypeExtension` behavior if using Ecto schemas with specialized types. For non-Ecto use, explicitly handle type conversions in application code.

### Raw NIF Access

Avoid `Exqlite.Sqlite3NIF` unless you have specific expertise with native implementation. Use higher-level APIs (`Exqlite.Connection`, `Exqlite.Basic`) instead.

---

**Version:** 0.39.0  
**Source:** [hexdocs.pm/exqlite](https://hexdocs.pm/exqlite/0.39.0)  
**Generated:** 2026-08-07
