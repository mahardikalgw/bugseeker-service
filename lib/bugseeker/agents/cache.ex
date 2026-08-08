defmodule Bugseeker.Agents.Cache do
  @moduledoc """
  Loads all review-agent Markdown files from `:agents_dir` at boot and serves
  them concurrently.

  Agents are cross-language review dimensions (Bug, Security, Performance, ...),
  analogous to language skills but applied to the whole PR diff. Each file is
  parsed with the same structure as skills: persona + `## Rules` + optional
  `## Severity` bias.
  """

  use GenServer

  alias Bugseeker.Agents.Agent

  @type t :: %{optional(String.t()) => Agent.t()}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns the loaded agent map, `%{name => %Skill{}}`."
  @spec all() :: t()
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Returns the agent for `name`, or `nil`."
  @spec get(String.t()) :: Agent.t() | nil
  def get(name), do: Map.get(all(), name)

  @doc "All available agent names."
  @spec all_names() :: [String.t()]
  def all_names, do: Map.keys(all()) |> Enum.sort()

  @impl true
  def init(_opts) do
    {:ok, load()}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state, state}

  defp load do
    subdir = Application.get_env(:bugseeker, :agents_dir, "priv/agents")
    # Resolve relative to the app root so it works in dev and in releases
    # (where priv/ is bundled).
    dir = Application.app_dir(:bugseeker, subdir)

    dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn path, acc ->
      # Name from the path relative to the agents dir, e.g.:
      #   security.md            -> "security"
      #   react_js/security.md   -> "react_js_security"
      relative =
        path
        |> Path.relative_to(dir)
        |> Path.rootname()
        |> String.replace("/", "_")

      agent = Agent.load(path, relative)
      Map.put(acc, agent.name, agent)
    end)
  end
end
