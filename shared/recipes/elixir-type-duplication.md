# Recipe: Elixir Type Duplication Detection and Resolution

## Problem

As Elixir codebases grow, type specifications (@spec) often contain duplicated type definitions that:

- Make code harder to maintain when types change
- Violate DRY principles
- Reduce readability with repeated verbose types
- Can lead to inconsistencies when only some duplicates are updated

## Solution

Systematically detect and resolve type duplication by:

- Using module-level type aliases (@type) for repeated types
- Implementing detection commands to find duplications
- Following consistent patterns for type extraction
- Maintaining backward compatibility during refactoring

## Implementation

### 1. Systematic Type Duplication Detection

#### Find Files with Type Duplication

```bash
# Find all files with Scope.t() duplication
git status --porcelain | grep -E '\.(ex|exs)$' | cut -c4- | xargs -I {} grep -l "@spec.*Scope\.t()" {} 2>/dev/null

# Count occurrences per file
git status --porcelain | grep -E '\.(ex|exs)$' | cut -c4- | xargs -I {} bash -c 'count=$(grep -c "@spec.*Scope\.t()" "{}" 2>/dev/null); if [ "$count" -gt 1 ]; then echo "{}: $count occurrences"; fi'

# Generic pattern for any type
git status --porcelain | grep -E '\.(ex|exs)$' | cut -c4- | xargs -I {} bash -c 'count=$(grep -c "@spec.*YourType\.t()" "{}" 2>/dev/null); if [ "$count" -gt 1 ]; then echo "{}: $count occurrences"; fi'
```

#### Find All Type Duplications in a File

```bash
# Extract all @spec type patterns and count duplicates
grep "@spec" lib/your_app/context.ex | grep -o '[A-Z][a-zA-Z]*\.t()' | sort | uniq -c | awk '$1 > 1 {print $2 ": " $1 " occurrences"}'
```

### 2. Type Resolution Pattern

#### Before: Type Duplication

```elixir
defmodule YourApp.JobPostings do
  alias YourApp.Accounts.Scope
  alias YourApp.JobPostings.JobPosting

  @spec list_job_postings(Scope.t()) :: [JobPosting.t()]
  def list_job_postings(%Scope{} = scope) do
    # implementation
  end

  @spec get_job_posting!(Scope.t(), String.t()) :: JobPosting.t()
  def get_job_posting!(%Scope{} = scope, id) do
    # implementation
  end

  @spec create_job_posting(Scope.t(), map()) :: {:ok, JobPosting.t()} | {:error, Ecto.Changeset.t()}
  def create_job_posting(%Scope{} = scope, attrs) do
    # implementation
  end

  @spec update_job_posting(Scope.t(), JobPosting.t(), map()) :: {:ok, JobPosting.t()} | {:error, Ecto.Changeset.t()}
  def update_job_posting(%Scope{} = scope, job_posting, attrs) do
    # implementation
  end

  @spec delete_job_posting(Scope.t(), JobPosting.t()) :: {:ok, JobPosting.t()} | {:error, Ecto.Changeset.t()}
  def delete_job_posting(%Scope{} = scope, job_posting) do
    # implementation
  end
end
```

#### After: Module-Level Type Aliases

```elixir
defmodule YourApp.JobPostings do
  alias YourApp.Accounts.Scope
  alias YourApp.JobPostings.JobPosting

  # Module-level type aliases eliminate duplication
  @type scope :: Scope.t()
  @type job_posting :: JobPosting.t()

  @spec list_job_postings(scope()) :: [job_posting()]
  def list_job_postings(%Scope{} = scope) do
    # implementation
  end

  @spec get_job_posting!(scope(), String.t()) :: job_posting()
  def get_job_posting!(%Scope{} = scope, id) do
    # implementation
  end

  @spec create_job_posting(scope(), map()) :: {:ok, job_posting()} | {:error, Ecto.Changeset.t()}
  def create_job_posting(%Scope{} = scope, attrs) do
    # implementation
  end

  @spec update_job_posting(scope(), job_posting(), map()) :: {:ok, job_posting()} | {:error, Ecto.Changeset.t()}
  def update_job_posting(%Scope{} = scope, job_posting, attrs) do
    # implementation
  end

  @spec delete_job_posting(scope(), job_posting()) :: {:ok, job_posting()} | {:error, Ecto.Changeset.t()}
  def delete_job_posting(%Scope{} = scope, job_posting) do
    # implementation
  end
end
```

### 3. Systematic Resolution Workflow

#### Step 1: Identify Duplications

```bash
# Run detection for specific file
grep "@spec" lib/your_app/job_postings.ex | grep -o '[A-Z][a-zA-Z]*\.t()' | sort | uniq -c | awk '$1 > 1'

# Expected output:
#   5 Scope.t()
#   5 JobPosting.t()
```

#### Step 2: Add Module-Level Type Aliases

```elixir
# Add after alias declarations, before first @spec
@type scope :: Scope.t()
@type job_posting :: JobPosting.t()
```

#### Step 3: Replace All Occurrences in @spec Declarations

```bash
# Use sed for systematic replacement (backup first)
cp lib/your_app/job_postings.ex lib/your_app/job_postings.ex.backup

sed -i 's/Scope\.t()/scope()/g' lib/your_app/job_postings.ex
sed -i 's/JobPosting\.t()/job_posting()/g' lib/your_app/job_postings.ex
```

#### Step 4: Verify Resolution

```bash
# Should show no duplications
grep "@spec" lib/your_app/job_postings.ex | grep -o '[A-Z][a-zA-Z]*\.t()' | sort | uniq -c | awk '$1 > 1'

# Verify compilation
mix compile
```

### 4. Automation Script

Create a script for systematic type duplication resolution:

```bash
#!/bin/bash
# File: scripts/fix_type_duplication.sh

FILE=$1
if [ -z "$FILE" ]; then
  echo "Usage: $0 <file_path>"
  exit 1
fi

echo "Analyzing type duplications in $FILE..."

# Backup original
cp "$FILE" "${FILE}.backup"

# Find duplicated types
DUPLICATES=$(grep "@spec" "$FILE" | grep -o '[A-Z][a-zA-Z0-9_]*\.t()' | sort | uniq -c | awk '$1 > 1 {print $2}')

if [ -z "$DUPLICATES" ]; then
  echo "No type duplications found in $FILE"
  rm "${FILE}.backup"
  exit 0
fi

echo "Found duplicated types:"
echo "$DUPLICATES"

# Create type aliases (insert after last alias line)
ALIAS_LINE=$(grep -n "alias " "$FILE" | tail -1 | cut -d: -f1)
if [ -n "$ALIAS_LINE" ]; then
  INSERT_LINE=$((ALIAS_LINE + 1))

  echo "" >> temp_aliases.txt
  echo "  # Module-level type aliases" >> temp_aliases.txt

  for TYPE in $DUPLICATES; do
    # Extract base name (e.g., Scope from Scope.t())
    BASE_NAME=$(echo "$TYPE" | sed 's/\.t()//')
    SNAKE_CASE=$(echo "$BASE_NAME" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//')
    echo "  @type $SNAKE_CASE :: $TYPE" >> temp_aliases.txt
  done

  # Insert type aliases
  head -n "$ALIAS_LINE" "$FILE" > temp_file.ex
  cat temp_aliases.txt >> temp_file.ex
  tail -n +$((INSERT_LINE)) "$FILE" >> temp_file.ex
  mv temp_file.ex "$FILE"
  rm temp_aliases.txt
fi

# Replace type occurrences in @spec declarations
for TYPE in $DUPLICATES; do
  BASE_NAME=$(echo "$TYPE" | sed 's/\.t()//')
  SNAKE_CASE=$(echo "$BASE_NAME" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//')
  sed -i "s/$TYPE/${SNAKE_CASE}()/g" "$FILE"
done

echo "Type duplication resolved. Backup saved as ${FILE}.backup"
echo "Verifying compilation..."

if mix compile; then
  echo "✅ Compilation successful"
  rm "${FILE}.backup"
else
  echo "❌ Compilation failed - restoring backup"
  mv "${FILE}.backup" "$FILE"
  exit 1
fi
```

### 5. Quality Gate Integration

Add to your CI pipeline or code review process:

```bash
# Check for type duplications in changed files
check_type_duplications() {
  for file in $(git diff --name-only HEAD~1 | grep '\.ex$'); do
    if [ -f "$file" ]; then
      duplicates=$(grep "@spec" "$file" | grep -o '[A-Z][a-zA-Z0-9_]*\.t()' | sort | uniq -c | awk '$1 > 1')
      if [ -n "$duplicates" ]; then
        echo "❌ Type duplications found in $file:"
        echo "$duplicates"
        return 1
      fi
    fi
  done
  echo "✅ No type duplications found"
  return 0
}
```

## Considerations

**When to Apply:**

- Any type appearing 2+ times in @spec declarations within the same module
- During code reviews as a quality gate
- Before major refactoring to improve maintainability
- When types become more complex and verbose

**Benefits:**

- **Maintainability**: Single point of change for type definitions
- **Readability**: Shorter, more semantic type names in specs
- **Consistency**: Reduces risk of inconsistent type usage
- **DRY Principle**: Eliminates code duplication

**Edge Cases:**

- External library types that shouldn't be aliased
- Types used only once (no duplication to resolve)
- Complex union types that might be better left explicit

**Testing Impact:**

- No impact on runtime behavior (types are compile-time only)
- Dialyzer should continue working with aliased types
- No test changes required

## Example Usage

### Before Resolution

```bash
$ grep "@spec" lib/bemeda_personal/job_applications.ex | grep -o 'Scope\.t()' | wc -l
8
```

### Apply Resolution

```bash
$ ./scripts/fix_type_duplication.sh lib/bemeda_personal/job_applications.ex
Analyzing type duplications in lib/bemeda_personal/job_applications.ex...
Found duplicated types:
Scope.t()
Type duplication resolved. Backup saved as lib/bemeda_personal/job_applications.ex.backup
Verifying compilation...
✅ Compilation successful
```

### After Resolution

```bash
$ grep "@spec" lib/bemeda_personal/job_applications.ex | grep -o 'Scope\.t()' | wc -l
0
$ grep "@type scope" lib/bemeda_personal/job_applications.ex
  @type scope :: Scope.t()
```

## Related Recipes

- Phoenix Scope-Based Authorization Pattern
- Elixir Code Quality Automation
- Systematic Refactoring with TDD
