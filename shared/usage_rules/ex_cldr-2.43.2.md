# ex_cldr

**ex_cldr** is an Elixir library providing access to the Unicode Consortium's Common Locale Data Repository (CLDR). It enables locale-specific formatting and parsing of numbers, currencies, dates, times, lists, and units of measure with full internationalization support.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:ex_cldr, "~> 2.43"},
    {:jason, "~> 1.0"}
  ]
end
```

Note: On OTP 27+ with Elixir 1.18+, JSON library configuration is automatic.

### Create Backend Module

```elixir
defmodule MyApp.Cldr do
  use Cldr,
    locales: ["en", "fr", "zh", "th"],
    default_locale: "en"
end
```

The backend module serves as the public API for all CLDR operations. Only explicitly configured locales are compiled, optimizing build time.

### Basic Usage

```elixir
# Get default locale
MyApp.Cldr.default_locale()  # => "en"

# Set/get current locale
MyApp.Cldr.put_locale("fr")
MyApp.Cldr.get_locale()  # => "fr"

# Validate locale
MyApp.Cldr.validate_locale("es")  # => {:ok, "es"}
MyApp.Cldr.validate_locale("invalid")  # => {:error, ...}

# List known locales
MyApp.Cldr.known_locale_names()
```

## Core Concepts

### Backend Module

A module invoking `use Cldr` that:

- Centralizes CLDR configuration
- Provides the public API for locale operations
- Compiles only configured locales
- Serves as entry point for all formatting/parsing functions

### Locale Configuration

**Explicit Configuration Only:**

- Only configured locales are compiled into the application
- Reduces build time and artifact size
- Each locale requires explicit inclusion

**Wildcard Patterns Supported:**

```elixir
use Cldr,
  locales: ["en", "fr-*", "zh-Hans", "zh-Hant"]
```

Patterns like `"en-*"` include all regional variants (en-US, en-GB, en-AU, etc.)

### Provider Packages

**Core Library:** `ex_cldr` provides locale data and backend configuration only.

**Specialized Providers:** Install additional packages for specific functionality:

- **Numbers:** `{:ex_cldr_numbers, "~> 2.30"}` - Number formatting and parsing
- **Dates/Times:** `{:ex_cldr_dates_times, "~> 2.16"}` - Date/time formatting
- **Units:** `{:ex_cldr_units, "~> 4.0"}` - Unit of measure formatting
- **Lists:** `{:ex_cldr_lists, "~> 2.10"}` - List formatting (and, or, or-and)
- **Currencies:** `{:ex_cldr_currencies, "~> 2.16"}` - Currency information and formatting

Each provider extends the backend module with domain-specific functions.

## Configuration

### Backend Options

```elixir
defmodule MyApp.Cldr do
  use Cldr,
    locales: ["en", "fr", "de"],           # Required: list of locales
    default_locale: "en",                   # Default locale for operations
    data_dir: "./cldr_data"                 # Optional: custom data directory
end
```

### Locale Naming

- **Language codes:** `"en"`, `"fr"`, `"de"` (ISO 639-1)
- **Regional variants:** `"en-US"`, `"en-GB"`, `"fr-CA"`, `"pt-BR"`
- **Script variants:** `"zh-Hans"` (Simplified), `"zh-Hant"` (Traditional)
- **Wildcard patterns:** `"en-*"` includes all English variants

### Runtime Locale Switching

```elixir
# Set locale for current process
MyApp.Cldr.put_locale("fr")

# Get current locale
MyApp.Cldr.get_locale()

# Validate before setting
case MyApp.Cldr.validate_locale("es") do
  {:ok, locale} -> MyApp.Cldr.put_locale(locale)
  {:error, reason} -> handle_error(reason)
end
```

## Best Practices

### 1. Centralize Backend Configuration

Create a single backend module (`MyApp.Cldr`) and use it throughout the application. Never create multiple backend modules.

### 2. Configure Only Required Locales

```elixir
# Good: Explicit locales
use Cldr,
  locales: ["en", "fr", "es"],
  default_locale: "en"

# Avoid: Unnecessary regional variants
use Cldr,
  locales: ["en-*"],  # Compiles all English variants
  default_locale: "en"
```

### 3. Use with Provider Packages

Core library handles locale data only. For actual formatting, use providers:

```elixir
# Install: {:ex_cldr_numbers, "~> 2.30"}
MyApp.Cldr.Number.to_string(1234.56, locale: "fr")  # "1 234,56"

# Install: {:ex_cldr_dates_times, "~> 2.16"}
MyApp.Cldr.DateTime.to_string(~U[2025-10-28 14:30:00Z], locale: "fr")
```

### 4. Validate User Input Locales

```elixir
def set_user_locale(user, locale_string) do
  case MyApp.Cldr.validate_locale(locale_string) do
    {:ok, locale} ->
      {:ok, Repo.update(User.changeset(user, %{locale: locale}))}
    {:error, reason} ->
      {:error, "Invalid locale: #{reason}"}
  end
end
```

### 5. Handle Locale Availability Gracefully

```elixir
def get_user_locale(user) do
  case MyApp.Cldr.validate_locale(user.locale) do
    {:ok, locale} -> locale
    {:error, _} -> MyApp.Cldr.default_locale()  # Fallback
  end
end
```

### 6. Cache Locale Information

```elixir
# In your backend module:
def known_locales do
  MyApp.Cldr.known_locale_names()
  |> Enum.map(fn locale -> {locale, locale} end)
end
```

### 7. Use with Phoenix

```elixir
# config/config.exs
config :my_app, MyApp.Cldr, locales: ["en", "fr", "de"]

# In Phoenix controller/view
def set_locale(locale) do
  case MyApp.Cldr.validate_locale(locale) do
    {:ok, valid_locale} ->
      MyApp.Cldr.put_locale(valid_locale)
    {:error, _} ->
      :ok
  end
end
```

### 8. Error Handling

```elixir
# Always validate locale strings from user input
validate_and_use = fn locale ->
  MyApp.Cldr.validate_locale(locale)
  |> case do
    {:ok, loc} -> {:ok, MyApp.Cldr.put_locale(loc)}
    {:error, _} -> {:error, :invalid_locale}
  end
end
```

---

**Version:** 2.43.2
**Source:** [hexdocs.pm/ex_cldr](https://hexdocs.pm/ex_cldr/)
**Generated:** 2025-10-28
