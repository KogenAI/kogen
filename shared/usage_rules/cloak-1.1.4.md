# cloak

Elixir encryption library implementing encryption best practices. Cloak provides random initialization vectors (IVs), tagged ciphertexts, and native Elixir configuration. Built on Erlang's `:crypto` library with optional Ecto integration through `cloak_ecto`.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:cloak, "~> 1.1"}
```

Run `mix deps.get`.

### Generate Encryption Key

Create a 256-bit Base64-encoded key in IEx:

```elixir
iex> 32 |> :crypto.strong_rand_bytes() |> Base.encode64()
# "your-base64-encoded-key-here"
```

### Create a Vault Module

Define a vault in your application:

```elixir
defmodule MyApp.Vault do
  use Cloak.Vault, otp_app: :my_app
end
```

### Configure the Vault

Add configuration to `config/config.exs`:

```elixir
config :my_app, MyApp.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("your-base64-key"),
      iv_length: 12
    }
  ]
```

### Add to Supervision Tree

In `lib/my_app/application.ex`, add your vault to the supervisor children:

```elixir
children = [
  MyApp.Vault,
  # ... other children
]
```

### Basic Usage

```elixir
{:ok, ciphertext} = MyApp.Vault.encrypt("plaintext")
{:ok, plaintext} = MyApp.Vault.decrypt(ciphertext)
# => {:ok, "plaintext"}
```

## Core Concepts

### Random IVs

Cloak automatically generates unique initialization vectors using `:crypto.strong_rand_bytes()` and embeds them in the ciphertext. This means identical plaintext values encrypt to different ciphertexts each time—a security best practice that requires no manual IV management.

### Tagged Ciphertexts

Each encrypted value includes metadata about which algorithm and key were used, enabling:

- Automatic cipher selection during decryption
- Seamless key rotation by adding new ciphers to the vault
- Support for multiple encryption algorithms simultaneously

### Multiple Vaults

Applications can run multiple vaults simultaneously:

```elixir
defmodule MyApp.AuthVault do
  use Cloak.Vault, otp_app: :my_app
end

defmodule MyApp.DataVault do
  use Cloak.Vault, otp_app: :my_app
end
```

Configure each separately in `config.exs` with different keys and algorithms.

## Configuration

### Cipher Options

**AES.GCM** (Galois/Counter Mode - recommended):

- `tag`: Unique identifier for this cipher version (e.g., "AES.GCM.V1")
- `key`: Base64-decoded 256-bit encryption key
- `iv_length`: Length of IV in bytes (typically 12 for GCM)

**AES.CTR** (Counter Mode):

- `tag`: Unique identifier
- `key`: Base64-decoded encryption key
- `iv_length`: IV length in bytes

### Runtime Configuration

Override configuration at startup using the `init/1` callback:

```elixir
defmodule MyApp.Vault do
  use Cloak.Vault, otp_app: :my_app

  def init(config) do
    config = Keyword.put(config, :ciphers, [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1",
        key: Base.decode64!(System.get_env("ENCRYPTION_KEY")),
        iv_length: 12
      }
    ])
    {:ok, config}
  end
end
```

### JSON Library

Cloak supports custom JSON libraries for serializing complex data before encryption. Default is Jason. Configure with:

```elixir
config :my_app, MyApp.Vault,
  json_library: Jason  # or your preferred library
```

## Ecto Integration

### Create Encrypted Field Types

Define Ecto types for your encrypted fields:

```elixir
defmodule MyApp.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: MyApp.Vault
end

defmodule MyApp.Encrypted.String do
  use Cloak.Ecto.String, vault: MyApp.Vault
end
```

### Apply to Schema Fields

```elixir
defmodule MyApp.User do
  use Ecto.Schema

  schema "users" do
    field :email, MyApp.Encrypted.String
    field :ssn, MyApp.Encrypted.Binary
    field :name, :string  # plaintext
    timestamps()
  end
end
```

### How It Works

- On write: Values are encrypted using configured cipher and stored as binary blobs
- On read: Encrypted blobs are automatically decrypted to original data type
- Transparent: Encryption/decryption happens automatically in changeset operations

## Best Practices

### Key Management

- **Never hardcode keys**: Always use environment variables or secret management systems
- **Key rotation**: Add new ciphers to support old encrypted data while encrypting new data with fresh keys
- **Key storage**: Store keys securely outside the application (e.g., AWS Secrets Manager, HashiCorp Vault)

### Ecto Limitations

- **Not searchable**: Since IVs are random, identical plaintext encrypts differently. Can't use `where` clauses on encrypted fields
- **Search workaround**: Store searchable hash alongside encrypted value, or denormalize unhashed values in separate search indexes
- **Data at rest**: Encrypted in database but plaintext in memory during application execution
- **No per-user keys**: Ecto types don't support per-user encryption—all encrypted fields share vault key

### Algorithm Selection

**Use AES.GCM for**:

- Security-sensitive data (PII, financial records)
- High-performance requirements (GCM has hardware acceleration)
- Authenticated encryption needs

**Use AES.CTR for**:

- Legacy compatibility requirements
- Scenarios where GCM isn't available

### Multiple Cipher Versions

Support key rotation by adding new ciphers:

```elixir
config :my_app, MyApp.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V2",
      key: Base.decode64!("new-key"),
      iv_length: 12
    },
    aes_gcm_v1: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("old-key"),
      iv_length: 12
    }
  ]
```

New data encrypts with "V2", old data with "V1" tags decrypt automatically.

### Error Handling

Use bang functions for non-production code, tuple-based returns for production:

```elixir
# Development: raises if decryption fails
plaintext = MyApp.Vault.decrypt!(ciphertext)

# Production: returns tuple
case MyApp.Vault.decrypt(ciphertext) do
  {:ok, plaintext} -> plaintext
  {:error, reason} -> handle_error(reason)
end
```

### Performance Considerations

- Vaults store configuration in ETS tables—no GenServer bottleneck
- Encryption/decryption runs locally in calling process
- Safe for high-throughput applications
- Minimal overhead compared to unencrypted operations

---

**Version:** 1.1.4
**Source:** [hexdocs.pm/cloak](https://hexdocs.pm/cloak/)
**Generated:** 2025-10-28
