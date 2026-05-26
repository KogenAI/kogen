# simple_sat

SimpleSat is a lightweight, dependency-free boolean satisfiability (SAT) solver for Elixir. Designed as a drop-in replacement for `picosat_elixir`, it solves boolean constraint problems without external dependencies.

## Quick Start

Add to `mix.exs`:

```elixir
def deps do
  [
    {:simple_sat, "~> 0.1.4"}
  ]
end
```

Basic usage:

```elixir
# Solve a satisfiability problem in CNF
SimpleSat.solve([[1], [1, 2], [-1]])
# => {:ok, [1, 2]} or {:ok, [1]} depending on solver choice
```

## Core Concepts

### Conjunctive Normal Form (CNF)

SimpleSat accepts problems in **CNF** — a conjunction (AND) of disjunctions (OR):

- **Positive integers** (`1`, `2`, `3`) represent variables being true
- **Negative integers** (`-1`, `-2`, `-3`) represent variables being negated/false
- **Each inner list** is a clause (disjunction — at least one must be true)
- **Outer list** requires ALL clauses to be true simultaneously

### Input Structure

```
[[clause1], [clause2], [clause3], ...]
```

Where each clause must have at least one true literal for the problem to be satisfiable.

## Usage Examples

### Simple Satisfiable Problems

```elixir
# A AND B AND C
# All three variables must be true
SimpleSat.solve([[1], [2], [3]])
# => {:ok, [1, 2, 3]}

# A AND (A OR B)
# A must be true, second clause is satisfied by A
SimpleSat.solve([[1], [1, 2]])
# => {:ok, [1]} or {:ok, [1, 2]}
```

### Unsatisfiable Problems

```elixir
# A AND (NOT A)
# Impossible to satisfy
SimpleSat.solve([[1], [-1]])
# => {:error, :unsatisfiable}
```

### Complex Constraints

```elixir
# (A OR B) AND (NOT A OR C) AND (NOT B OR C)
# Requires careful variable assignment
SimpleSat.solve([[1, 2], [-1, 3], [-2, 3]])
# => {:ok, solution} if satisfiable
```

## Best Practices

### Problem Modeling

1. **Variable Numbering**: Use positive integers (1, 2, 3...) to represent variables
2. **Negation**: Use negative integers to represent NOT conditions
3. **CNF Conversion**: Convert your boolean logic to CNF before solving
4. **Clause Structure**: Each clause is a list of literals that must include at least one true value

### Performance Considerations

- SimpleSat is lightweight and dependency-free, suitable for constraint problems in Phoenix/Ash applications
- For large constraint problems with thousands of variables, consider the solver's algorithmic limits
- Use as a drop-in replacement for `picosat_elixir` in Ash Framework integration

### Error Handling

```elixir
case SimpleSat.solve(clauses) do
  {:ok, solution} ->
    # Use the solution
    process_solution(solution)
  {:error, :unsatisfiable} ->
    # Handle unsatisfiable constraints
    raise "Constraints cannot be satisfied"
end
```

### Integration with Ash

SimpleSat was designed primarily to support Ash Framework's constraint solver. Use as a dependency-free SAT solver for Ash validation and constraint problems.

---

**Version:** 0.1.4
**Source:** [hexdocs.pm/simple_sat](https://hexdocs.pm/simple_sat/)
**Generated:** 2025-10-28
