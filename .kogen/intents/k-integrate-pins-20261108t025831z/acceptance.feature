Feature: Qualify fixed component runtime fixtures
  The reported stand-ins at .kogen/claude-code/2.1.318/claude were 229-519 bytes.
  The darwin-arm64 pin requires 319598464 bytes; linux-x64 requires 337814032 bytes.
  Sparse padding must preserve the executable version and auth-status responses.

  Scenario: Consume the executor runtime contract without bypasses
    Then k-integrate-pins-20261108t025831z: the consumed executor contract package passes
