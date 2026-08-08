defmodule Bugseeker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Bugseeker.Repo,
      Bugseeker.Agents.Cache,
      Bugseeker.PerRepo,
      Bugseeker.Github.AppAuth,
      Bugseeker.Stats,
      {Oban, Application.fetch_env!(:oban, Oban)},
      # Start to serve requests, typically the last entry
      BugseekerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Bugseeker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BugseekerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
