# gettext

Gettext is an Elixir library implementing GNU gettext-based internationalization. It provides compile-time message extraction, plural-aware translations, and locale management for multi-language applications.

## Quick Start

**Create a backend module:**

```elixir
defmodule MyApp.Gettext do
  use Gettext.Backend, otp_app: :my_app
end
```

**Replace hardcoded strings with gettext calls:**

```elixir
import MyApp.Gettext
gettext("Hello, world!")
```

**Extract messages and create translations:**

```bash
mix gettext.extract       # Creates .pot template files
mix gettext.merge priv/gettext  # Updates locale-specific .po files
```

## Core Concepts

**Message IDs and Translation Flow**

English source text functions as both the display default and the message identifier. Running `mix gettext.extract` creates `.pot` template files containing message IDs. Subsequent `mix gettext.merge` updates locale-specific `.po` files with actual translations from translators.

**Fuzzy Matching**

When you modify English strings, gettext performs fuzzy matching during the next merge, automatically updating message IDs while flagging entries for translator review. This minimizes translation maintenance when source text changes.

**Interpolation**

Messages support dynamic values via `%{key}` syntax:

```elixir
gettext("Hello, %{name}!", name: "Alice")
```

Values are passed as keyword arguments or maps and substituted at runtime.

## Configuration

**Backend Options**

- `:priv` — message directory (default: `"priv/gettext"`)
- `:default_locale` — fallback locale
- `:plural_forms` — custom pluralization module for non-standard languages
- `:split_module_by` — optimize compilation for large projects by splitting modules

**Locale Management**

Set locale per-process for multi-tenant applications:

```elixir
Gettext.put_locale(MyApp.Gettext, "es")  # Set locale for current process
Gettext.get_locale(MyApp.Gettext)         # Retrieve current locale
Gettext.known_locales(MyApp.Gettext)      # List available locales
```

## Translation Functions

- `gettext(msgid)` — simple message translation
- `ngettext(msgid, msgid_plural, count)` — plural-aware translation (returns singular or plural form based on count)
- `dgettext(domain, msgid)` — domain-specific translation for organizing messages
- `pgettext(context, msgid)` — context-based translation for disambiguating identical strings with different meanings

## Best Practices

- **Use macros at compile time** — Write `gettext()` calls directly in source code rather than constructing strings dynamically. This ensures `mix gettext.extract` finds all translatable strings.
- **Leverage fuzzy matching** — Update English text freely; gettext flags changed entries for translator review without losing translation history.
- **Set locale per-process** — Use `put_locale/2` in request handlers or process initialization for clean multi-tenant separation.
- **Organize with domains** — Group related messages using domains like "errors", "emails", or "notifications" to avoid collisions and improve maintainability.
- **Plan pluralization early** — Use `ngettext/5` even when singular forms suffice; languages have different plural rules (some have 0, 1, 2+, etc.).
- **Extract regularly** — Run `mix gettext.extract` during development to keep `.pot` files current, reducing merge conflicts for translators.

---

**Version:** 1.0.2  
**Source:** [hexdocs.pm/gettext](https://hexdocs.pm/gettext)  
**Generated:** 2026-04-25
