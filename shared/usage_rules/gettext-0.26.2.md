# gettext

Gettext provides internationalization (i18n) support for Elixir applications using the GNU gettext standard. It allows you to replace hardcoded text with translation function calls, enabling multi-language support while keeping the original English string as both the default display text and the message ID for translation lookups.

## Quick Start

### 1. Create Backend Module

```elixir
defmodule MyApp.Gettext do
  use Gettext.Backend, otp_app: :my_app
end
```

### 2. Add Translations to Modules

Import the Gettext macro to any module needing translations:

```elixir
use Gettext, backend: MyApp.Gettext

def greet(name) do
  gettext("Hello, %{name}!", name: name)
end
```

### 3. Extract and Merge Translations

```bash
# Extract gettext() calls into .pot template files
mix gettext.extract

# Update locale-specific .po files with new message IDs
mix gettext.merge priv/gettext
```

### 4. Translate and Compile

Add translations to `.po` files in `priv/gettext/[locale]/LC_MESSAGES/` and Gettext automatically compiles them.

## Core Concepts

### Translation Functions

- **`gettext(string)`** - Simple messages in default domain
- **`ngettext(singular, plural, count)`** - Pluralized messages
- **`dgettext(domain, string)`** - Domain-scoped messages (organize by feature)
- **`pgettext(context, string)`** - Context-based messages (disambiguate identical strings with different meanings)
- **Combined variants**: `dpgettext`, `dngettext`, `pngettext`, `dpngettext`

### Locale Management

Gettext stores locale per-process using process dictionaries:

```elixir
# Set global locale for current process
Gettext.put_locale(locale)

# Set locale for specific backend
Gettext.put_locale(MyApp.Gettext, locale)

# Get current locale
Gettext.get_locale()

# Temporarily switch locale
Gettext.with_locale(locale, fn -> gettext("message") end)
```

### Interpolation

Support for dynamic value insertion in translated strings:

```elixir
gettext("Welcome, %{user}!", user: user_name)
```

The `%{variable}` syntax works with any atom key passed as a keyword argument.

### Fuzzy Matching

When source strings change, Gettext marks similar translations as "fuzzy," signaling translators for review without breaking existing translations. This prevents incorrect translations from being used.

## Configuration

### Backend Options

Configure when using `Gettext.Backend`:

```elixir
use Gettext.Backend,
  otp_app: :my_app,
  priv: "priv/gettext",              # Custom messages directory
  default_locale: "en",              # Backend-specific fallback
  plural_forms: MyApp.PluralForms,   # Custom pluralization module
  split_module_by: 100               # Optimize compilation for large projects
```

### Application Configuration

```elixir
# config/config.exs
config :gettext, :default_locale, "en"
```

### Directory Structure

Gettext expects translations in a strict directory layout:

```
priv/gettext/
├── errors.pot                    # Template file (all strings)
├── messages.pot
├── de/
│   └── LC_MESSAGES/
│       ├── errors.po            # German translations
│       └── messages.po
└── fr/
    └── LC_MESSAGES/
        ├── errors.po            # French translations
        └── messages.po
```

## Best Practices

### Compile-Time String Literals

Always use string literals with macros for automatic extraction and dependency optimization:

```elixir
# ✅ Good - compile-time, auto-extracted, optimized
use Gettext, backend: MyApp.Gettext
gettext("Hello")

# ❌ Avoid - dynamic strings miss extraction
dynamic_string = "Hello"
gettext(dynamic_string)
```

### Domain Organization

Use domains to organize translations by feature or responsibility:

```elixir
# Keep errors, UI messages, and notifications separate
dgettext("errors", "Invalid email")
dgettext("notifications", "Email sent successfully")
dgettext("ui", "Save Changes")
```

### Context for Disambiguation

Use context when the same string has different meanings:

```elixir
# Without context, these conflict:
pgettext("noun", "Reply")      # Email feature
pgettext("verb", "Reply")      # Chat feature
```

### Locale Per-Process

Always set locale per-process (e.g., per HTTP request) since Gettext stores it in process dictionaries. In Phoenix, set in `:put_user_languages` plug:

```elixir
Gettext.put_locale(MyApp.Gettext, conn.assigns.locale)
```

### Fuzzy Mark Strategy

Leverage fuzzy marking to track translation updates needed after source strings change. Review and clear fuzzy marks before releasing to ensure accurate translations.

### Pluralization Rules

Different locales follow distinct pluralization patterns. Gettext automatically applies the correct forms based on count and locale. Use `ngettext` consistently for countable items.

---

**Version:** 0.26.2
**Source:** [hexdocs.pm/gettext](https://hexdocs.pm/gettext/)
**Generated:** 2025-10-28
