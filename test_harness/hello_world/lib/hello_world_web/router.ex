defmodule HelloWorldWeb.Router do
  use HelloWorldWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HelloWorldWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HelloWorldWeb do
    pipe_through :browser

    live "/", HelloLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", HelloWorldWeb do
  #   pipe_through :api
  # end
end
