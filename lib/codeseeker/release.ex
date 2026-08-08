defmodule Codeseeker.Release do
  @moduledoc """
  Helpers for running Ecto migrations from within a production release,
  where `mix` is not available.
  """

  @app :codeseeker

  @doc "Runs all pending migrations for every configured repo."
  def migrate do
    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, migrations_path(repo), :up, all: true)
        )
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp migrations_path(repo), do: Ecto.Migrator.migrations_path(repo)
end
