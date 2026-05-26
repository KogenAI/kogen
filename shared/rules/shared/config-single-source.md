# Config as Single Source of Truth

Shell launcher + Elixir runner read same config keys. Two configs for one component (harness.build.claude AND roles.build) → silent drift.

One canonical path. Both consumers read it. Rename → grep all, update together.

❌ Duplicate model/tool per consumer
✅ Shared key, consumers reference
