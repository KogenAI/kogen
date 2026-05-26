# faker

Faker is a pure Elixir library for generating realistic fake data across diverse categories. It provides lightweight, language-specific modules for testing, seeding, and development workflows without external API dependencies.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:faker, "~> 0.18", only: :test}
  ]
end
```

Run `mix deps.get` to fetch dependencies.

### Initialization

Add to `test/test_helper.exs` to start Faker:

```elixir
Faker.start()
ExUnit.start()
```

### Basic Usage

Generate fake data with module functions:

```elixir
Faker.Person.name()              # "John Doe"
Faker.Address.city()             # "New York"
Faker.Internet.email()           # "john@example.com"
Faker.Company.name()             # "Tech Corp"
Faker.Lorem.sentence()           # Random sentence
Faker.Date.date_of_birth()       # Random date
```

## Core Concepts

### Data Categories

**Person & Identity**: `Faker.Person` generates names, emails, usernames with multilingual support (English, Spanish, French, Armenian, Italian, Brazilian Portuguese)

**Location**: `Faker.Address` provides cities, streets, postcodes, states. `Faker.Airports` for airport codes

**Business**: `Faker.Company` (names, catchphrases), `Faker.Industry` (sector names)

**Communication**: `Faker.Internet` (URLs, usernames, emails), `Faker.Phone` (phone numbers with country variants), `Faker.Email`

**Finance**: `Faker.Finance` (account numbers, routing numbers), `Faker.Finance.Stock` (tickers, market data), `Faker.Commerce` (product names, prices), `Faker.Currency`

**Technology**: `Faker.Aws` (AWS resources), `Faker.Code` (IBAN codes), `Faker.UUID` (unique identifiers), `Faker.Blockchain` (Bitcoin/Ethereum addresses)

**Creative Content**: `Faker.Lorem` (placeholder text), `Faker.Lorem.Shakespeare` (Shakespeare quotes), `Faker.Markdown`, `Faker.String`

**Entertainment**: `Faker.Pokemon`, `Faker.StarWars`, `Faker.Superhero`, `Faker.App` (app names)

**Miscellaneous**: `Faker.Animal`, `Faker.Food`, `Faker.Beer`, `Faker.Pizza`, `Faker.Vehicle`, `Faker.Date`, `Faker.DateTime`, `Faker.File`, `Faker.Avatar`, `Faker.Nato`

### Language Support

Most modules support language-specific variants:

```elixir
Faker.Person.name()              # English (default)
Faker.Person.En.name()           # Explicitly English
Faker.Person.Es.name()           # Spanish
Faker.Person.Fr.name()           # French
Faker.Address.PtBr.city()        # Brazilian Portuguese
```

## Configuration

Faker requires no explicit configuration for basic usage. Ensure `:faker` is listed in dependencies and `Faker.start()` is called in test setup.

### Common Patterns in Tests

Generate fixtures with Faker:

```elixir
def user_fixture(attrs \\ %{}) do
  {:ok, user} = Users.create_user(
    Map.merge(%{
      name: Faker.Person.name(),
      email: Faker.Internet.email(),
      password: "test_password"
    }, attrs)
  )
  user
end
```

Create factories for testing:

```elixir
defmodule MyApp.Factory do
  def user_params(attrs \\ %{}) do
    Map.merge(%{
      name: Faker.Person.name(),
      email: Faker.Internet.email(),
      address: Faker.Address.city()
    }, attrs)
  end
end
```

## Best Practices

**Use for test data only**: Restrict Faker to `:test` environment in `mix.exs` to avoid production dependencies

**Initialize early**: Call `Faker.start()` in `test_helper.exs` before test execution

**Combine with factories**: Use Faker within factory functions to generate varied, realistic test data while maintaining control over required attributes

**Override when needed**: Pass test data directly to override Faker-generated values, ensuring specific edge cases are tested

**Leverage language variants**: Use language-specific modules (`Faker.Person.Es`, `Faker.Address.PtBr`) for multilingual application testing

**Deterministic seeding**: For reproducible tests, set the random seed before running Faker if needed

**Avoid in seeds**: Do not use Faker for production seed files—use deterministic or manually defined data instead

---

**Version:** 0.18.0
**Source:** [hexdocs.pm/faker](https://hexdocs.pm/faker/)
**Generated:** 2025-10-28
