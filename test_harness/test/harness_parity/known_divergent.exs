# Divergence allowlist for harness parity tests.
# Each entry: {scenario :: String.t(), harness :: String.t(), reason :: String.t()}.
# An entry suppresses the shared-contract equality assertion for that exact
# scenario x harness pair; the parity test then asserts the documented degraded
# contract and surfaces `reason` in the test output.
# Ships EMPTY: no known divergences today. A future legitimate divergence is a
# one-line edit here WITH a written reason — never a `@tag :skip` or a deleted
# assertion (see pitch No-gos).
[]
