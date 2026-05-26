defmodule HelloWorld.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HelloWorldWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hello_world, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: HelloWorld.PubSub},
      # Start a worker by calling: HelloWorld.Worker.start_link(arg)
      # {HelloWorld.Worker, arg},
      # Start to serve requests, typically the last entry
      HelloWorldWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HelloWorld.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HelloWorldWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
