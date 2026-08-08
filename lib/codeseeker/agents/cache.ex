defmodule Codeseeker.Agents.Cache do
  @moduledoc """
  Loads all review-agent Markdown files from `:agents_dir` at boot and serves
  them concurrently.

  Agents are cross-language review dimensions (Bug, Security, Performance, ...),
  analogous to language skills but applied to the whole PR diff. Each file is
  parsed with the same structure as skills: persona + `## Rules` + optional
  `## Severity` bias.
  """

  use GenServer

  alias Codeseeker.Skills.Skill

  @type t :: %{optional(String.t()) => Skill.t()}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns the loaded agent map, `%{name => %Skill{}}`."
  @spec all() :: t()
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Returns the agent for `name`, or `nil`."
  @spec get(String.t()) :: Skill.t() | nil
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
    dir = Application.get_env(:codeseeker, :agents_dir, "agents")

    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn path, acc ->
      # Flat layout (agents/bug.md), so the name is the filename.
      skill = Skill.load(path, Path.basename(path, ".md"))
      Map.put(acc, skill.name, skill)
    end)
  end
end
