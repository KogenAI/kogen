# Phoenix Feature Test Runner with Proper Cleanup

## Problem

When running Phoenix feature tests with PhoenixTest.Playwright:

1. Interrupting tests with Ctrl+C leaves orphaned test servers running on port
2. Retry mechanisms slow down development by re-running failed tests
3. No easy way to run specific test files or line numbers
4. Test server processes accumulate and cause port conflicts

## Solution

A bash script with intelligent cleanup that:

- Only kills test servers, not the test runner itself
- Handles interrupts gracefully
- Supports file and line number arguments
- Cleans up before and after test runs

## Implementation

### 1. Create the Feature Test Script

Create `scripts/feature_test.sh`:

```bash
#!/bin/bash

# Feature test runner with proper cleanup
# Only cleans up orphaned processes, not the current test

export FEATURE_TESTS=true
export PW_TIMEOUT=2000

# Store our own PID to avoid killing ourselves
SCRIPT_PID=$$

# Function to kill ONLY the test server, not the test runner
cleanup_on_exit() {
    echo -e "\n🧹 Cleaning up test server..."

    # Only kill processes on port 4205 (the test server)
    # This won't kill the test runner itself
    if lsof -ti tcp:4205 > /dev/null 2>&1; then
        echo "  Stopping test server on port 4205..."
        lsof -ti tcp:4205 | xargs kill -9 2>/dev/null || true
    fi

    echo "  Cleanup complete ✓"
}

# Function for interrupt cleanup (Ctrl+C) - more aggressive
cleanup_on_interrupt() {
    echo -e "\n⚠️  Interrupted! Cleaning up..."

    # Kill test server
    lsof -ti tcp:4205 | xargs kill -9 2>/dev/null || true

    # Kill any child processes of this script
    pkill -P $SCRIPT_PID 2>/dev/null || true

    echo "  Cleanup complete ✓"
    exit 130
}

# Set up different handlers for different situations
trap cleanup_on_interrupt INT  # Ctrl+C
trap cleanup_on_exit EXIT      # Normal exit

# Kill any existing test server before starting (but don't kill running tests)
if lsof -ti tcp:4205 > /dev/null 2>&1; then
    echo "🧹 Cleaning up existing test server..."
    lsof -ti tcp:4205 | xargs kill -9 2>/dev/null || true
fi

# Run mix test
echo "🚀 Starting feature tests..."
mix test --color --only feature "$@"
TEST_EXIT_CODE=$?

# Exit with the test's exit code (cleanup happens via EXIT trap)
exit $TEST_EXIT_CODE
```

Make it executable:

```bash
chmod +x scripts/feature_test.sh
```

### 2. Configure Mix Alias

Update `mix.exs` aliases:

```elixir
defp aliases do
  [
    # ... other aliases
    "test.features": [
      "assets.deploy",
      fn args ->
        # Clean up any existing test server first
        System.cmd("bash", ["-c", "lsof -ti tcp:4205 | xargs kill -9 2>/dev/null || true"])

        # Run the feature test script
        cmd_args = Enum.join(args, " ")
        Mix.shell().cmd("./scripts/feature_test.sh #{cmd_args}")
      end
    ]
  ]
end
```

### 3. Configure Test Environment

Ensure `config/test.exs` has proper feature test setup:

```elixir
# Only start server when FEATURE_TESTS is set
if System.get_env("FEATURE_TESTS") == "true" do
  config :your_app, YourAppWeb.Endpoint,
    http: [port: 4205],
    server: true
end
```

## Usage

### Three Ways to Run Tests

#### Option 1: Mix Alias (Recommended)

```bash
# Run all feature tests
mix test.features

# Run specific file
mix test.features test/path/to/file.exs

# Run specific test by line number
mix test.features test/path/to/file.exs:123
```

#### Option 2: Direct Script (Best Cleanup)

```bash
# Run all feature tests
./scripts/feature_test.sh

# Run specific file
./scripts/feature_test.sh test/path/to/file.exs

# Run specific test by line number
./scripts/feature_test.sh test/path/to/file.exs:123
```

#### Option 3: Direct Mix Command

```bash
# Set environment variables first
export FEATURE_TESTS=true
export PW_TIMEOUT=2000

# Run tests
mix test --only feature
mix test --only feature test/path/to/file.exs:123
```

## Key Features

### 1. Smart Cleanup

The script distinguishes between:

- **Normal exit**: Only kills test server on port 4205
- **Interrupt (Ctrl+C)**: Kills test server and child processes
- **Pre-test**: Cleans up any existing test servers

### 2. No Self-Termination

Previous implementations would accidentally kill the test runner itself. This solution:

- Stores the script's PID
- Only kills test server processes (port 4205)
- Never kills the parent test runner

### 3. Signal Handling

```bash
trap cleanup_on_interrupt INT  # Handles Ctrl+C
trap cleanup_on_exit EXIT      # Handles normal completion
```

## Common Issues and Solutions

### Issue: Test Server Already Running

**Symptom**: `port 4205 already in use`
**Solution**: The script automatically kills existing servers before starting

### Issue: Orphaned Processes After Interrupt

**Symptom**: Test server keeps running after Ctrl+C
**Solution**: The INT trap handler aggressively cleans up

### Issue: Tests Kill Themselves Mid-Run

**Symptom**: Tests stop with "killed" message
**Solution**: Use port-specific cleanup instead of process name matching

## Manual Cleanup Commands

If needed, manually clean up:

```bash
# Kill test server on port 4205
lsof -ti tcp:4205 | xargs kill -9

# Kill all mix test processes (nuclear option)
pkill -f "mix test"

# Check what's using the port
lsof -i tcp:4205
```

## Text Assertion Fix for PhoenixTest.Playwright

When using this setup with PhoenixTest.Playwright, remember the text assertion fix:

```elixir
# ❌ WRONG - Fails due to whitespace
|> assert_has("First Job")

# ✅ CORRECT - Handles whitespace properly
|> assert_has("a", text: "First Job", exact: false)
```

## Benefits

1. **Fast Development**: No retry mechanism, tests fail fast
2. **Clean Environment**: No orphaned processes accumulate
3. **Flexible Running**: Support for specific files and line numbers
4. **Reliable Cleanup**: Works on both normal exit and interrupt
5. **Safe Operation**: Won't accidentally kill the test runner

## Implementation Timeline

- **2025-08-12**: Initial implementation with aggressive cleanup
- **2025-08-12**: Fixed self-termination bug
- **2025-08-12**: Added smart cleanup distinction between exit types
- **2025-08-12**: Integrated with mix aliases

## Related Recipes

- `phoenix-feature-test-debugging.md` - Debugging strategies
- `phoenix-async-feature-test-liveview.md` - Async test setup
- `phoenix-feature-test-setup.md` - Full test environment

## Tags

#testing #phoenix #playwright #cleanup #bash #devtools
