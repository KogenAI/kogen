# Empty-store login-status probe

The CLI version was not captured in this status-only invocation; do not infer
it from earlier probes. A subsequent delegated probe reported 0.154.0.
Run in temporary directories with private HOME and
CODEX_HOME, file credential store and a minimal environment. No real credential
file was read or copied; no model turn or login was attempted. The probe ran
`codex -c cli_auth_credentials_store=\"file\" login status` with an empty store,
then with a synthetic OPENAI_API_KEY, then a synthetic CODEX_API_KEY. Temporary
files were removed after completion.

```json
[
  {
    "case": "empty",
    "exit": 1,
    "reports_not_logged_in": true,
    "reports_api_key": false,
    "auth_file_created": false
  },
  {
    "case": "api_environment",
    "exit": 1,
    "reports_not_logged_in": true,
    "reports_api_key": false,
    "auth_file_created": false
  },
  {
    "case": "codex_api_environment",
    "exit": 1,
    "reports_not_logged_in": true,
    "reports_api_key": false,
    "auth_file_created": false
  }
]
```

This establishes only local status behavior for those inputs. It is not proof
that a stored token is current, that a subscription has remaining allowance,
that a selected model is accessible, or that a later exec command will ignore
all provider environment variables. Wrapper readiness must not overclaim.
