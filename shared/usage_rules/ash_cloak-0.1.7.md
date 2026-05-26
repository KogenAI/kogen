# ash_cloak

AshCloak is an Ash extension that seamlessly encrypts and decrypts attributes of your resources, ensuring sensitive fields are not stored in plaintext in your data layer. It works with any Ash data layer and provides flexible vault implementation options.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:ash_cloak, "~> 0.1.7"}
  ]
end
```

### Basic Setup

1. Configure a vault (Cloak is recommended):

```elixir
config :my_app, :ash_cloak_vault, MyApp.Vault
```

2. Add to your resource:

```elixir
defmodule MyApp.User do
  use Ash.Resource

  extensions [AshCloak]

  attributes do
    attribute :email, :string
    attribute :encrypted_email, :string, sensitive?: true
  end
end
```

## Core Concepts

### Attribute Encryption

AshCloak encrypts individual resource attributes transparently at the resource level. When you configure an attribute for encryption, AshCloak:

- Handles encryption/decryption seamlessly during attribute operations
- Stores encrypted data in designated encrypted attributes
- Prevents plaintext sensitive data from being stored in your data layer
- Works universally with any Ash data layer (Postgres, SQLite, etc.)

### Vault Integration

AshCloak requires a vault for encryption operations. Cloak is recommended but you can implement custom vault solutions. The vault handles:

- Encryption key management
- Actual encryption/decryption operations
- Key rotation strategies

### Key Functions

**cloak/1** - Core macro for setting up encryption on a resource

**encrypt_and_set/3** - Encrypts and writes to an encrypted attribute

- Accepts: changeset, attribute name (atom), and value
- Returns: updated `Ash.Changeset.t()`
- Behavior: Adds before-action hook if changeset hasn't started execution; runs immediately otherwise
- Raises: `AshCloak.Errors.NoSuchEncryptedAttribute` if attribute lacks encryption configuration

## Configuration

### Resource Configuration

```elixir
defmodule MyApp.Account do
  use Ash.Resource

  extensions [AshCloak]

  attributes do
    # Store encrypted version here
    attribute :encrypted_ssn, :string, sensitive?: true
    # Optional: original attribute for input
    attribute :ssn, :string
  end
end
```

### Vault Configuration

Configure your vault in `config/config.exs`:

```elixir
config :my_app, MyApp.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode16!("YOUR_KEY_HERE")
    }
  ]
```

### Error Handling

AshCloak raises `NoSuchEncryptedAttribute` when:

- Attempting to decrypt an attribute without encryption configuration
- Using encrypt_and_set on non-encrypted attributes

## Best Practices

### Sensitive Data Protection

- Mark encrypted attributes with `sensitive?: true` to prevent exposure in logs
- Only encrypt truly sensitive fields (passwords, SSNs, credit cards, PII)
- Store encrypted data in dedicated attributes (convention: `encrypted_{field}`)

### Key Management

- Use proper vault implementations with secure key rotation
- Never hardcode encryption keys in source code
- Use environment variables or secure key management systems
- Implement key rotation strategies for compliance requirements

### Performance Considerations

- Encryption/decryption adds computational overhead; consider impact on bulk operations
- Use indexed encrypted attributes carefully (encrypted values hash differently each encryption)
- Consider separate encrypted attribute strategy for frequently searched fields

### Integration Patterns

- Use `encrypt_and_set/3` within change functions to handle encryption workflows
- Validate encrypted attributes early in changeset pipelines
- Combine with Ash policies for access control to encrypted data
- Test encryption/decryption flows thoroughly before production

### Common Patterns

- Store user input in temporary attribute, encrypt to permanent encrypted attribute via change function
- Use custom changes that invoke `encrypt_and_set/3` for flexible encryption workflows
- Pair encrypted attributes with metadata (encrypted_at, vault_version) for audit trails
- Implement selective decryption based on user permissions

---

**Version:** 0.1.7
**Source:** [hexdocs.pm/ash_cloak](https://hexdocs.pm/ash_cloak/)
**Generated:** 2025-10-28
