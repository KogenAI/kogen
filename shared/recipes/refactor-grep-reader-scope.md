# Refactoring: Grep Scope & Reader Verification

When removing a field/function/constant, verify zero readers by scanning across **lib/, config/, bin/** AND reading runtime paths (boot, deploy, startup hooks). Filename grep alone misses:

- Same-name fields in unrelated contexts (`custom_domain_verified_at`, DNS `verified_at`, etc.)
- Hardcoded paths / exec'd external scripts (`bin/deploy` jq-reads `.field`, shell scripts parse JSON)
- Boot/deploy paths baked into the binary at compile-time

**Pattern**:

1. Grep lib/, config/, bin/ for the field name (catch direct refs + aliases)
2. Read boot sequence in source (`Application.start`, `config/runtime.exs`) — look for config readers
3. Read deploy/init scripts (`bin/deploy`, `bin/release-day-gate.sh`) — look for JSON/env consumers
4. Read Oban worker boots (`BuildWorker.check_codegen_pin!/0`) — look for required fields
5. Read test fixtures — ensure they're stale if the field is truly unused

Example: removing `verified_at` from codegen lock. Grep finds only one writer (`Mix.Tasks.Codegen.Pin.write_lock/2`). Boot gate reads only `codegen_commit` + `harness_versions`. Deploy script jq-reads only `.codegen_commit` / `.harness_versions.codegen_call` / `.tests_last_green_at` — no `verified_at` consumer. Test fixtures already omit it. Safe to remove.
