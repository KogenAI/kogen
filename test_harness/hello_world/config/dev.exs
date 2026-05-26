import Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :hello_world, HelloWorldWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "GfqVJy3wZXq7UX5Zr9vVJY5dVQR3zQQdvVQR3zQQdvVQR3zQQdvVQR3zQQdvVQRGfqVJy3wZXq7",
  watchers: []

# Reload browser tabs when matching files change.
config :hello_world, HelloWorldWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      # Gettext translations
      ~r"priv/gettext/.*\.po$"E,
      # Router, Controllers, LiveViews and LiveComponents
      ~r"lib/hello_world_web/router\.ex$"E,
      ~r"lib/hello_world_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :hello_world, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
