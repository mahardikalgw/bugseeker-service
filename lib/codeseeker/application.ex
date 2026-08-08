defmodule Codeseeker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Codeseeker.Repo,
      Codeseeker.Agents.Cache,
      Codeseeker.PerRepo,
      Codeseeker.Github.AppAuth,
      Codeseeker.Stats,
      {Oban, Application.fetch_env!(:oban, Oban)},
      # Start to serve requests, typically the last entry
      CodeseekerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Codeseeker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CodeseekerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
