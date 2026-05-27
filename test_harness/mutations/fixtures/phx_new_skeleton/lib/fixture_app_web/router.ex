defmodule FixtureAppWeb.Router do
  use FixtureAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FixtureAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", FixtureAppWeb do
    pipe_through :browser

    get "/", PageController, :home
  end
end
