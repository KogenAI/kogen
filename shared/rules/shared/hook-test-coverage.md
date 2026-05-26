# Hook Test Coverage Minimum

Every guard → ≥14 cases: both DENY and ALLOW paths. Silent failures (grep partial, null crash, missing //) caught by tests, not review.

❌ Ship guard with 2 happy-path tests
✅ Edge cases, role boundaries, null fields
