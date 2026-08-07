defmodule Codeseeker.CoordinatorSup do
  @moduledoc """
  DynamicSupervisor that runs one `Codeseeker.Coordinator` GenServer per
  PR. Multiple PRs run concurrently; concurrency inside a PR is bounded by
  `Task.async_stream`'s `max_concurrency`.
  """

  use DynamicSupervisor

  alias Codeseeker.Coordinator

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Starts a coordinator for a PR payload:

      %{repo: %{owner: ..., name: ..., github_repo_id: ..., installation_id: ...},
        pr_number: ..., head_sha: ..., base_sha: ...}
  """
  @spec start_child(map()) :: DynamicSupervisor.on_start_child()
  def start_child(pr) do
    DynamicSupervisor.start_child(__MODULE__, {Coordinator, pr})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: 50,
      max_restarts: 5,
      max_seconds: 10
    )
  end
end
