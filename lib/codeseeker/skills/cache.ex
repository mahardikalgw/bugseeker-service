defmodule Codeseeker.Skills.Cache do
  @moduledoc """
  Loads all skill Markdown files from `:skills_dir` at boot and serves
  them concurrently. Skills are code (they live in `skills/` and are
  versioned with Git), so a restart picks up edits.
  """

  use GenServer

  alias Codeseeker.Skills.Skill

  @type t :: %{optional(String.t()) => Skill.t()}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns the loaded skill map, `%{name => %Skill{}}`."
  @spec all() :: t()
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Returns the skill for `name`, or `nil`."
  @spec get(String.t()) :: Skill.t() | nil
  def get(name), do: Map.get(all(), name)

  @doc "Returns all available skill names."
  @spec all_names() :: [String.t()]
  def all_names, do: Map.keys(all()) |> Enum.sort()

  @doc "Re-reads the skills directory (used by tests and after editing skills)."
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl true
  def init(_opts) do
    {:ok, load()}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state, state}

  def handle_call(:reload, _from, _state) do
    {:reply, :ok, load()}
  end

  defp load do
    dir = Application.get_env(:codeseeker, :skills_dir, "skills")

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.reduce(%{}, fn filename, acc ->
      path = Path.join(dir, filename)
      skill = Skill.load(path)
      Map.put(acc, skill.name, skill)
    end)
  end
end
