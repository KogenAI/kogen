defmodule HelloWorldWeb.HelloLive do
  use HelloWorldWeb, :live_view

  def render(assigns) do
    ~H"""
    <div>hello world</div>
    """
  end
end
