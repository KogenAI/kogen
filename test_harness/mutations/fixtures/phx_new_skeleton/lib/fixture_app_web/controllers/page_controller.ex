defmodule FixtureAppWeb.PageController do
  use FixtureAppWeb, :controller

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end
end
