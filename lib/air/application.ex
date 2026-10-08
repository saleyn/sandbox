defmodule Air.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AirWeb.Telemetry,
      Air.Repo,
      {DNSCluster, query: Application.get_env(:air, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Air.PubSub},
      # Listens to Postgres notifications and broadcasts them to LiveViews
      Air.DbListener,
      # Supervises the background processes that step through a simulated
      # DAG run (see Air.DagRunSimulator) so a crash there can't take down
      # the app.
      {Task.Supervisor, name: Air.TaskSupervisor},
      # Start a worker by calling: Air.Worker.start_link(arg)
      # {Air.Worker, arg},
      # Start to serve requests, typically the last entry
      AirWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Air.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AirWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
