# Nested offline suites must not write their fixture records into the parent
# Build's raw evidence directory. Tests that capture logs set their own path.
System.delete_env("KOGEN_RAW_LOG_DIR")

# Fixture commits exercise Git publication without depending on a developer's
# signing key or an interactive signing agent. This override is confined to
# the test process and its disposable repositories.
config_count = System.get_env("GIT_CONFIG_COUNT", "0") |> String.to_integer()
System.put_env("GIT_CONFIG_KEY_#{config_count}", "commit.gpgsign")
System.put_env("GIT_CONFIG_VALUE_#{config_count}", "false")
System.put_env("GIT_CONFIG_COUNT", Integer.to_string(config_count + 1))

ExUnit.start(exclude: [:live])
