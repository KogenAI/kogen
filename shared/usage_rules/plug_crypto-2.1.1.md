# plug_crypto

Plug.Crypto provides cryptographic functionality for web applications, offering secure encryption, message authentication, and key derivation utilities. It is a core dependency of the Plug framework.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [{:plug_crypto, "~> 2.1"}]
end
```

Run `mix deps.get` to fetch the dependency. If you're using Plug, Plug.Crypto is available as a transitive dependency.

### Basic Usage

```elixir
# Encrypt and decrypt data
encrypted = Plug.Crypto.encrypt("secret_key", "data")
{:ok, decrypted} = Plug.Crypto.decrypt("secret_key", encrypted)

# Generate secure random bytes
random_bytes = Plug.Crypto.random_bytes(16)

# Hash passwords using PBKDF2
hash = Plug.Crypto.hash_password("mypassword")
true = Plug.Crypto.verify_password("mypassword", hash)
```

## Core Concepts

### Key Modules

#### `Plug.Crypto.MessageVerifier`

Provides message authentication and signing. Creates cryptographic signatures for messages.

- `sign(data, secret)` - Creates a signed message
- `verify(signed, secret)` - Verifies a signed message
- `verify!(signed, secret)` - Verifies and raises on failure

```elixir
signed = Plug.Crypto.MessageVerifier.sign("user:123", secret)
{:ok, data} = Plug.Crypto.MessageVerifier.verify(signed, secret)
```

#### `Plug.Crypto.KeyGenerator`

Derives cryptographic keys using PBKDF2 (Password-Based Key Derivation Function 2).

- `generate(password, opts)` - Derives a key from a password
- Default iterations: 160,000

```elixir
key = Plug.Crypto.KeyGenerator.generate("password", [])
```

#### `Plug.Crypto.Ciphers`

Core encryption operations for AES and other algorithms.

- Supports AES-GCM and AES-CBC modes
- Key sizes: 128, 192, 256 bits
- Authentication tag verification included

### Encryption Patterns

**AES-GCM Encryption (Authenticated):**

```elixir
# Encrypt with AES-GCM (recommended)
{encrypted_data, tag} = Plug.Crypto.Ciphers.encrypt(
  :aes_256_gcm,
  key,
  iv,
  "",
  plaintext
)

# Decrypt
plaintext = Plug.Crypto.Ciphers.decrypt(
  :aes_256_gcm,
  key,
  iv,
  tag,
  encrypted_data
)
```

### Random Generation

```elixir
# Generate cryptographically secure random bytes
random_16_bytes = Plug.Crypto.random_bytes(16)
random_32_bytes = Plug.Crypto.random_bytes(32)
```

## Configuration

Plug.Crypto uses `:crypto` and `:ssl` from Erlang/OTP. No explicit Elixir configuration needed, but ensure your system's OpenSSL is up-to-date for security patches.

### Algorithm Selection

**Recommended:**

- **AES-GCM**: Provides both encryption and authentication (preferred)
- **PBKDF2**: For key derivation with configurable iterations

**Avoid:**

- **AES-CBC**: Requires separate message authentication code
- **Old/Deprecated ciphers**: DES, RC4 not available

### Key Management Best Practices

```elixir
# Store keys in environment variables or secrets manager
secret_key = System.get_env("SECRET_KEY_BASE")

# Generate keys with sufficient entropy
iv = Plug.Crypto.random_bytes(16)  # For GCM/CBC
salt = Plug.Crypto.random_bytes(16) # For key derivation

# Rotate keys periodically
# Keep old keys for decryption grace period
```

## Best Practices

### Session Security

1. **Use Phoenix Sessions** instead of manual encryption when possible—they integrate Plug.Crypto correctly
2. **Set secure cookie options**: `http_only`, `secure`, `same_site`
3. **Rotate session keys periodically**

### Message Verification

Use `MessageVerifier` for CSRF tokens and signed data:

```elixir
# In controller
token = Plug.Crypto.MessageVerifier.sign(form_id, secret)

# In template
<%= hidden_input_tag :csrf_token, @csrf_token %>

# In another controller
{:ok, data} = Plug.Crypto.MessageVerifier.verify(received_token, secret)
```

### Password Hashing

Never store plaintext passwords. Use built-in or Argon2:

```elixir
# Plug.Crypto uses PBKDF2 internally
hash = Plug.Crypto.hash_password("user_password")
verify = Plug.Crypto.verify_password("user_input", hash)
```

For additional security, consider `Argon2` or `Bcrypt` packages.

### Common Pitfalls

1. **Hardcoding secrets** in code—use environment variables
2. **Reusing IVs** for AES-CBC/GCM—always generate new random IV per encryption
3. **Short keys**—use at least 256-bit keys for AES
4. **Ignoring verification tags** in GCM mode—always verify before decrypting
5. **Insufficient iterations** for PBKDF2—default 160,000 is recommended minimum
6. **String vs. Binary confusion**—ensure inputs are binary (use `<< >>` syntax for binary literals)

### Error Handling

```elixir
# Message verification returns {:error, :invalid}
case Plug.Crypto.MessageVerifier.verify(token, secret) do
  {:ok, data} -> handle_valid(data)
  :error -> handle_invalid()
end

# Encryption/decryption may raise on invalid data
try do
  result = Plug.Crypto.Ciphers.decrypt(:aes_256_gcm, key, iv, tag, ciphertext)
rescue
  e in ArgumentError -> handle_decrypt_error(e)
end
```

### Erlang/OTP Versions

- Plug.Crypto 2.1.1 requires OTP 20+
- Modern crypto functions require OTP 23+ for best compatibility
- Verify your project's `:crypto` module version: `crypto:info_lib()`

## Version-Specific Notes

**2.1.1 Release Notes:**

- Stable cryptographic API for Plug framework
- AES-GCM authenticated encryption support
- PBKDF2 key derivation with secure defaults
- MessageVerifier for signing and authentication
- No breaking changes from 2.0.x

---

**Version:** 2.1.1  
**Source:** https://github.com/elixir-plug/plug_crypto  
**License:** Apache License 2.0  
**Generated:** 2026-06-17
