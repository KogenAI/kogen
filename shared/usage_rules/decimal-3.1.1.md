# decimal

A lightweight library for arbitrary-precision decimal arithmetic in Elixir. Decimal numbers are represented as `sign * coefficient * 10 ^ exponent`, following IEEE 754 decimal128 standards to ensure exact calculations without floating-point precision loss.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [
    {:decimal, "~> 3.1"}
  ]
end
```

### Basic Usage

```elixir
# Creating decimals from strings (preserves precision)
price = Decimal.new("19.99")
discount = Decimal.new("0.15")

# Arithmetic operations
total = Decimal.mult(price, 5)
discounted = Decimal.mult(price, Decimal.sub(1, discount))

# Comparison
Decimal.compare("1.0", 1)  # :eq
Decimal.eq?("1.0", 1)      # true
Decimal.gt?("1.3", "1.2")  # true
```

## Core Concepts

### Precision Preservation

"A decimal number will always be created exactly as specified with all digits kept." Trailing zeros are maintained unless explicitly removed via normalization.

```elixir
Decimal.new("3.140")  # Preserves trailing zero
Decimal.normalize(Decimal.new("3.140"))  # Removes trailing zero
```

### Creating Decimals

| Method                                     | Use Case                                                |
| ------------------------------------------ | ------------------------------------------------------- |
| `Decimal.new(value)`                       | From integers or strings (recommended for strings)      |
| `Decimal.from_float(float)`                | Converting floats (less precise due to IEEE 754)        |
| `Decimal.new(sign, coefficient, exponent)` | From components; `Decimal.new(1, 314, -2)` creates 3.14 |

### Special Values

The library handles edge cases per IEEE 754 decimal128:

- **NaN and ±Infinity**: Propagate through operations correctly
- **Signed Zero**: `-0` and `+0` are distinct values
- **Quiet NaN**: Propagates through calculations

### Significant Digits

Default context maintains 34 significant digits following IEEE 754 decimal128 specifications. Operations on precision-exceeding numbers follow standard rounding rules.

## Configuration

### Context Configuration

Decimal behavior is controlled via a context structure (when needed for custom precision):

```elixir
# Default context maintains 34 significant digits
# Most applications use the default without explicit configuration
```

### Rounding

Rounding follows IEEE 754 standards. The default context applies rounding when precision limits are exceeded during operations.

### Normalization

Remove trailing zeros:

```elixir
Decimal.normalize(Decimal.new("3.140"))  # => Decimal representing 3.14
```

## Arithmetic Operations

```elixir
# Basic operations
Decimal.add("1.1", 1)           # Decimal addition
Decimal.sub(1, "0.1")           # Decimal subtraction
Decimal.mult("0.5", 3)          # Decimal multiplication
Decimal.div(3, 4)               # Decimal division returns "0.75"

# Comparisons
Decimal.eq?("1.0", 1)           # true (semantic equality)
Decimal.eq?("1.2", 1, "0.2")    # Threshold-based comparison
Decimal.compare(a, b)            # Returns :lt, :eq, or :gt
```

## Best Practices

### 1. Use Strings for Precision

Always use strings for decimal input to avoid floating-point precision loss:

```elixir
# Good: preserves exact value
price = Decimal.new("19.99")

# Avoid: IEEE 754 imprecision
price = Decimal.from_float(19.99)
```

### 2. Handle Untrusted Input

Apply parsing and validation limits to prevent pathological inputs:

```elixir
# Validate string format and length before Decimal.new/1
input = "123.45"
case Decimal.new(input) do
  {:ok, decimal} -> decimal
  :error -> handle_invalid()
end
```

### 3. Normalize When Needed

Remove trailing zeros for cleaner output only when required:

```elixir
result = Decimal.normalize(Decimal.new("3.140"))
```

### 4. JSON Encoding

Decimals encode as strings by default to preserve precision:

```elixir
# Decimal automatically serializes as string in JSON context
# Ensures no precision loss during encoding/decoding
```

### 5. Type Checking in Guards

Use `Decimal.is_decimal/1` for pattern matching in guards (OTP 21+):

```elixir
def process(value) when Decimal.is_decimal(value) do
  # Handle decimal
end
```

### 6. Financial and Scientific Calculations

Ideal for:

- Money/currency calculations (exact cents representation)
- Scientific calculations requiring arbitrary precision
- Tax, discount, and rounding-sensitive computations

Avoid IEEE 754 floats for these use cases entirely.

---

**Version:** 3.1.1  
**Source:** [hexdocs.pm/decimal](https://hexdocs.pm/decimal)  
**Generated:** 2026-08-07
