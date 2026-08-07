# faker

Faker is an Elixir library for generating realistic fake data across multiple categories. It provides a simple API for creating test data including names, addresses, emails, phone numbers, and other common data types without making external API calls.

## Quick Start

Add Faker to your `mix.exs` dependencies (test environment only):

```elixir
defp deps do
  [
    {:faker, "~> 0.19.0", only: :test}
  ]
end
```

Initialize in `test/test_helper.exs`:

```elixir
ExUnit.start()
Faker.start()
```

Basic usage in tests:

```elixir
Faker.Person.name()           # "Mrs. Abe Rolfson MD"
Faker.Internet.email()         # "elizabeth2056@rolfson.net"
Faker.Address.street_address() # "15426 Aniya Mews"
```

## Core Concepts

### Module Organization

Faker organizes generators by data type into distinct modules. Each module contains functions that return randomized but realistic values:

- **Faker.Person** - Names, prefixes, suffixes, titles
- **Faker.Internet** - Emails, URLs, usernames, IP addresses, MAC addresses, domain names
- **Faker.Address** - Streets, cities, states, countries, postal codes, geographic coordinates
- **Faker.DateTime** - Dates, times, and timestamps
- **Faker.Company** - Company names and industry descriptors
- **Faker.Code** - Various formatted codes and identifiers

### Locale Support

Faker supports multiple locales for region-specific data generation:

```elixir
Faker.start(:en)   # English locale
Faker.start(:fr)   # French locale
Faker.locale(:de)  # Switch to German
```

### String Formatting

Use the `Faker.format/1` function to generate formatted strings where `#` is replaced with random digits and `?` is replaced with random Latin letters:

```elixir
Faker.format("###-??-####") # "534-AB-7821"
```

### Random Utilities

Core randomization functions available on the main Faker module:

- `random_between(left, right)` - Integer within range
- `random_uniform()` - Float between 0.0 and 1.0
- `random_bytes(total)` - Random binary data
- `shuffle(enum)` - Randomize enumerable order

## Configuration

### Initialization

Faker must be started before use. The recommended approach is in `test/test_helper.exs`:

```elixir
ExUnit.start()
Faker.start()
```

Optionally pass a locale:

```elixir
Faker.start(:de)  # Start with German locale
```

### Setting Locale at Runtime

Change the locale after initialization:

```elixir
Faker.locale(:fr)      # Switch to French
current = Faker.locale() # Get current locale
```

### System Requirements

- OTP 19 or higher
- Elixir 1.6 or higher

## Best Practices

### Dependency Scope

Always add Faker to the `:test` environment only to avoid including test dependencies in production builds:

```elixir
{:faker, "~> 0.19.0", only: :test}
```

### Initialization Order

Ensure `Faker.start()` is called before any Faker functions are used. Place it at the beginning of your test suite setup to avoid "no function clause matching" errors.

### Locale for Context

Use locale configuration to generate region-appropriate test data. This helps validate that your application handles different locales correctly.

### Combining Generators

Chain multiple Faker functions to create realistic composite data:

```elixir
person_email = "#{Faker.Person.first_name() |> String.downcase()}@#{Faker.Internet.domain_name()}"
full_address = "#{Faker.Address.street_address()}, #{Faker.Address.city()}, #{Faker.Address.state_abbr()}"
```

### Secondary Address Support

Use secondary address functions for multi-unit buildings:

```elixir
Faker.Address.street_address(true)   # Includes apartment/suite number
Faker.Address.secondary_address()    # Just the unit designator
```

### URL Generation

The `image_url()` function generates placeholder image URLs from external services (placekitten.com, picsum.photos). Use these for testing image handling:

```elixir
Faker.Internet.image_url()  # Returns valid placeholder image URL
```

---

**Version:** 0.19.0
**Source:** [hexdocs.pm/faker](https://hexdocs.pm/faker/0.19.0)
**Generated:** 2026-08-07
