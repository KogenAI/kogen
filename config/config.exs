import Config

# stdout carries only protocol messages (CLI-4, CLI-9); logs go to stderr (kogen sets the same
# for the Erlang reports logged before Elixir's Logger starts).
config :logger, :default_handler, config: [type: :standard_error]
