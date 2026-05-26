# joken

Joken is an Elixir JSON Web Token (JWT) library built on JOSE that provides token creation, signing, verification, and validation with claims processing.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:joken, "~> 2.6"},
    {:jason, "~> 1.4"}
  ]
end
```

### Basic Usage

Module-based approach (recommended):

```elixir
defmodule MyApp.Auth do
  use Joken.Config
end

# Generate and sign
claims = %{"user_id" => 123}
{:ok, token, _claims} = MyApp.Auth.encode_and_sign(claims)

# Verify and validate
{:ok, claims} = MyApp.Auth.verify_and_validate(token)
```

Pure data structure approach:

```elixir
signer = Joken.Signer.create("HS256", "secret")
{:ok, token, _claims} = Joken.generate_and_sign(MyApp.Auth.token_config(), claims, signer)
```

## Core Concepts

### Token Configuration

Define token structure via `Joken.Config` module using `use Joken.Config` macro, which generates:

- `token_config/0` — returns configuration map with claims
- `encode_and_sign/2` — creates and signs tokens
- `verify/2` — verifies JWT signature
- `validate/2` — validates claims
- `generate_claims/1` — generates dynamic claim values

### Claims

Standard JWT claims ("exp", "iat", "nbf", "iss", "aud", "jti") are available via `default_claims/1`. Add custom claims with `add_claim/5`:

```elixir
add_claim("user_id", &generate_user_id/0, &validate_user_id/1)
```

Each claim includes:

- Generator function — produces value at token creation
- Validator function — verifies claim on verification
- Optional custom options

### Signers

Joken abstracts signing algorithms through `Joken.Signer`:

- **Symmetric**: HS256, HS384, HS512
- **Asymmetric**: RS256, RS384, RS512, ES256, ES384, ES512, PS256, PS384, PS512

Create signers explicitly or load from `config.exs`:

```elixir
signer = Joken.Signer.create("HS256", "your-secret")
```

### Verification Flow

`verify_and_validate/5` performs:

1. Signature verification using signer
2. Claim validation via configured validators
3. Returns claims or detailed error tuple with reason

## Configuration

### In config.exs

```elixir
config :joken, signers: [
  default: [signer_alg: "HS256", key_octet_file: "path/to/key"]
]
```

### Module Configuration

Override `token_config/0` and `signer/0` in your module:

```elixir
defmodule MyApp.Auth do
  use Joken.Config

  def token_config do
    default_claims(iss: "myapp")
    |> add_claim("user_id", &generate_user_id/0, &validate_user_id/1)
  end

  def signer do
    Joken.Signer.create("HS256", "secret")
  end

  defp generate_user_id, do: {:ok, current_user_id()}
  defp validate_user_id(user_id), do: {:ok, user_id}
end
```

### Asymmetric Signers

For RSA/EC keys:

```elixir
signer = Joken.Signer.create("RS256", {"RSA", key})
```

Load from files or key material in config.exs with `key_file` or `key_octet_file`.

## Best Practices

1. **Use Module Encapsulation** — Define `Joken.Config` modules per token type (auth, refresh, webhook) for cleaner organization and testability.

2. **Leverage default_claims/1** — Always configure standard claims (exp, iss, aud) for security and clarity. Expiration is critical.

3. **Custom Validators** — Implement validators for custom claims; never trust unvalidated token data. Validation happens on every verification.

4. **Signer Management** — Load signers from config.exs (not hardcoded) and rotate keys via configuration changes. Keep secrets secure.

5. **Error Handling** — `verify_and_validate` returns detailed error tuples; inspect reasons for logging and debugging (signature failure, claim validation error, malformed token).

6. **Testing Integration** — Create test signers and use module-based configuration for easy mock/override in tests. Joken integrates cleanly with ExUnit.

7. **Hooks for Lifecycle Events** — Use `add_hook/2` for side effects (logging, metrics) on token generation/verification without blocking main logic.

8. **Peek Before Full Validation** — Use `peek_claims/1` and `peek_header/1` to inspect tokens without validation (useful for debugging or conditional logic).

9. **Performance** — HS256 is fastest; RS256/ES256 suit high-throughput scenarios with precomputed keys. Benchmark for your use case.

10. **Claims Design** — Minimize claims size for compact tokens; store user data server-side, use claims for lightweight identity/permissions metadata only.

---

**Version:** 2.6.2
**Source:** [hexdocs.pm/joken](https://hexdocs.pm/joken/)
**Generated:** 2026-04-25
