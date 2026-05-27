defmodule FixtureAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fixture_app

  @session_options [
    store: :cookie,
    key: "_fixture_app_key",
    signing_salt: "abcdefgh",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :fixture_app,
    gzip: false,
    only: FixtureAppWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug FixtureAppWeb.Router
end
