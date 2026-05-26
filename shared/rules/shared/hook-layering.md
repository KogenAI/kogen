# Hook Guard Layering

Universal hooks (no-cat-pipe, pre-commit) → fire every role. Role-specific (debug-bash-safety, planner-guard) → gate role boundaries only.

One hook = one concern.

❌ Mix universal + role checks
✅ Separate files, separate registrations
