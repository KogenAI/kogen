import Config

# Configure your database
config :fixture_app, FixtureApp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "fixture_app_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
