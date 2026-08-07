# plug_crypto

Plug.Crypto provides cryptographic functions for Elixir applications, specializing in message signing, verification, and encryption. It powers secure cookie handling, session management, and tamper-proof token generation in Phoenix and other web frameworks.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:plug_crypto, "~> 2.2"}
  ]
end
```

Run `mix deps.get` to install.

### Basic Usage

**Signing and verifying a message:**

```elixir
secret_key = "your-secret-key-base"
salt = "message-verifier"

# Sign a message
{:ok, signed} = Plug.Crypto.sign(secret_key, salt, "sensitive-data")

# Verify the message
{:ok, data} = Plug.Crypto.verify(secret_key, salt, signed)
```

**Encrypting and decrypting:**

```elixir
# Encrypt a message
{:ok, encrypted} = Plug.Crypto.encrypt(secret_key, salt, "secret-message")

# Decrypt the message
{:ok, decrypted} = Plug.Crypto.decrypt(secret_key, salt, encrypted)
```

## Core Concepts

### Message Verification vs. Encryption

**MessageVerifier**: Signs data to prevent tampering. Data remains readable but cannot be modified without detection. Use for scenarios where clients can view information but shouldn't alter it (e.g., cookies, tokens).

**MessageEncryptor**: Encrypts data using XChaCha20-Poly1305 authenticated encryption. Data is unreadable without the decryption key. Use when you need to prevent users from reading encrypted payloads.

### Security Functions

**secure_compare/2**: Performs constant-time binary comparison to prevent timing attacks. Essential when comparing sensitive values like tokens or signatures.

```elixir
Plug.Crypto.secure_compare(token, expected_token)
```

**mask/2**: Masks tokens using XOR operations for additional security context.

### Safe Deserialization

**non_executable_binary_to_term/2**: Safely deserializes binaries while blocking executable terms (modules, atoms). Prevents code injection vulnerabilities when deserializing untrusted data.

```elixir
{:ok, term} = Plug.Crypto.non_executable_binary_to_term(binary, [:safe])
```

## Configuration

All signing and encryption functions support configuration options:

| Option            | Default      | Purpose                                    |
| ----------------- | ------------ | ------------------------------------------ |
| `:key_iterations` | 1000         | PBKDF2 rounds for key derivation           |
| `:key_length`     | 32 bytes     | Derived key size                           |
| `:key_digest`     | `:sha256`    | Hash algorithm for key derivation          |
| `:max_age`        | 86400 (24h)  | Token validity duration in seconds         |
| `:signed_at`      | current time | Custom token timestamp                     |
| `:compressed`     | false        | Enable term compression                    |
| `:local`          | false        | Runtime-specific encoding (Erlang/OTP 26+) |

### Example with Options

```elixir
# Sign with custom key derivation
Plug.Crypto.sign(secret, salt, data, key_iterations: 2000, key_digest: :sha512)

# Verify with max_age constraint
{:ok, data} = Plug.Crypto.verify(secret, salt, signed, max_age: 3600)
# Returns {:error, :expired} if signed more than 1 hour ago
```

## Best Practices

### 1. Key Management

- Use cryptographically random `secret_key_base` with at least 64 characters of entropy
- Never hardcode secrets; load from environment variables or secret management systems
- Rotate secrets periodically; Plug.Crypto supports multiple secrets for gradual migration

### 2. Salt Selection

- Use distinct salt values for different purposes (sessions, CSRF tokens, password resets)
- Prevents cross-context token forgery
- Example: `"session-verifier"`, `"csrf-token"`, `"password-reset"`

### 3. Choosing the Right Tool

| Use Case                  | Tool                      | Why                             |
| ------------------------- | ------------------------- | ------------------------------- |
| Cookies, readable tokens  | MessageVerifier           | Fast, tamper-proof              |
| Sensitive data encryption | MessageEncryptor          | Prevents unauthorized reading   |
| Session tokens            | MessageVerifier + max_age | Combines integrity + expiration |
| CSRF tokens               | MessageVerifier           | Lightweight verification        |

### 4. Error Handling

Always match on verification results:

```elixir
case Plug.Crypto.verify(secret, salt, token, max_age: 3600) do
  {:ok, data} -> {:ok, data}
  {:error, :expired} -> {:error, "Token expired"}
  {:error, :invalid} -> {:error, "Tampered token"}
end
```

### 5. Logging and Debugging

Use `prune_args_from_stacktrace/1` to remove sensitive arguments from error traces before logging:

```elixir
trace = Plug.Crypto.prune_args_from_stacktrace(stacktrace)
Logger.error("Error: #{inspect(trace)}")
```

### 6. Constant-Time Comparisons

Always use `secure_compare/2` when comparing tokens:

```elixir
if Plug.Crypto.secure_compare(provided_token, expected_token) do
  # Token valid
end
```

### 7. Performance Optimization

Functions cache derived keys by default. For high-throughput applications:

- Key derivation is PBKDF2-based; reduce `:key_iterations` only if acceptable for your security model
- Encryption/verification are fast; main bottleneck is key derivation
- Use consistent salt values to maximize cache hits

---

**Version:** 2.2.0
**Source:** [plug-crypto.hexdocs.pm](https://plug-crypto.hexdocs.pm/)
**Generated:** 2026-08-07
