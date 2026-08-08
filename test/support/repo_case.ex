defmodule Codeseeker.RepoCase do
  @moduledoc """
  Shared setup for tests that touch the database / Oban. Must be used with
  `async: false`.

  Checks out the sandbox connection, sets up Mox global mode, and stops any
  leaked coordinators.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Codeseeker.RepoCase
      import Ecto.Query
      import Mox

      alias Codeseeker.Repo

      @moduletag :repo_case

      setup do
        Mox.set_mox_global()
        Mox.verify_on_exit!()
        Ecto.Adapters.SQL.Sandbox.checkout(Codeseeker.Repo)
        :ok
      end
    end
  end

  @doc "Builds a unique PR payload hash (avoid DB unique collisions across tests)."
  def unique_sha(prefix), do: prefix <> "_" <> to_string(:erlang.unique_integer([:positive]))

  @doc "Inserts a pr_review row directly for job tests."
  def insert_pr_review!(attrs) do
    defaults = %{
      github_repo_id: 100,
      owner: "acme-internal",
      name: "web-frontend",
      installation_id: 42,
      pr_number: 12,
      head_sha: unique_sha("head"),
      base_sha: "base0000",
      status: "pending",
      total_files: 1,
      files_reviewed: 0
    }

    {:ok, pr_review} =
      Codeseeker.Reviews.create_pr_review(Map.merge(defaults, Map.new(attrs)))

    pr_review
  end

  @doc "Performs a job for `worker` with `args`, returning its result."
  def perform(worker, args) do
    Oban.Testing.perform_job(worker, args, repo: Codeseeker.Repo)
  end

  @doc "Returns jobs enqueued for a worker (with the Oban repo bound)."
  def enqueued(worker) do
    Oban.Testing.all_enqueued(repo: Codeseeker.Repo, worker: worker)
  end
end
