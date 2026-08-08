defmodule Codeseeker.PerRepo do
  @moduledoc """
  In-memory per-repo configuration: whether the bot is enabled for the
  repo, which skills are active, and the inline-severity threshold.

  Initialized from `config :codeseeker, :repos` at boot; mutated at
  runtime by `/codeseeker` commands. Runtime-only changes are lost on
  restart — persist them in `config/repos.exs`.
  """

  use Agent

  @type repo :: %{required(:owner) => String.t(), required(:name) => String.t()}
  @type state :: %{optional(String.t()) => map()}

  def start_link(_opts) do
    Agent.start_link(fn -> Application.get_env(:codeseeker, :repos, %{}) end, name: __MODULE__)
  end

  @doc "True when the bot should process this repo (default: true)."
  @spec enabled?(repo()) :: boolean()
  def enabled?(repo) do
    get(repo)[:enabled] != false
  end

  @doc "Skills active for the repo, or `:all` when the repo has no override."
  @spec skills(repo()) :: :all | [String.t()]
  def skills(repo) do
    case get(repo)[:skills] do
      nil -> :all
      list when is_list(list) -> list
    end
  end

  @doc "Inline-severity threshold for the repo, or the global default."
  @spec min_inline_severity(repo()) :: String.t()
  def min_inline_severity(repo) do
    get(repo)[:min_inline_severity] ||
      Application.get_env(:codeseeker, :min_inline_severity, "HIGH")
  end

  @doc "Current overrides for the repo, or an empty map."
  @spec overrides(repo()) :: map()
  def overrides(repo), do: get(repo) || %{}

  @doc "Enables a skill for the repo at runtime."
  @spec enable_skill(repo(), String.t()) :: :ok
  def enable_skill(repo, skill_name) do
    update(repo, fn overrides ->
      current = Map.get(overrides, :skills) || Enum.map(Codeseeker.Skills.Cache.all_names(), & &1)
      Map.put(overrides, :skills, Enum.uniq([skill_name | current]))
    end)
  end

  @doc "Disables a skill for the repo at runtime."
  @spec disable_skill(repo(), String.t()) :: :ok
  def disable_skill(repo, skill_name) do
    update(repo, fn overrides ->
      current = Map.get(overrides, :skills) || Enum.map(Codeseeker.Skills.Cache.all_names(), & &1)
      Map.put(overrides, :skills, current -- [skill_name])
    end)
  end

  @doc "Sets the inline-severity threshold for the repo at runtime."
  @spec set_min_inline_severity(repo(), String.t()) :: :ok
  def set_min_inline_severity(repo, severity) do
    update(repo, &Map.put(&1, :min_inline_severity, String.upcase(severity)))
  end

  @doc "Toggles whether the bot processes this repo at runtime."
  @spec set_enabled(repo(), boolean()) :: :ok
  def set_enabled(repo, enabled) do
    update(repo, &Map.put(&1, :enabled, enabled))
  end

  @doc "The repo's active skills, resolved: `:all` becomes the full manifest."
  @spec active_skill_names(repo()) :: [String.t()]
  def active_skill_names(repo) do
    case skills(repo) do
      :all -> Enum.map(Codeseeker.Skills.Cache.all_names(), & &1)
      list -> list
    end
  end

  defp get(repo), do: Agent.get(__MODULE__, &Map.get(&1, key(repo)))

  defp update(repo, fun) do
    Agent.update(__MODULE__, fn state ->
      current = Map.get(state, key(repo)) || %{}
      Map.put(state, key(repo), fun.(current))
    end)
  end

  # Repo maps arrive as atom keys from webhooks/commands and as string keys
  # from Oban job args — accept both.
  defp key(repo) do
    owner = Map.get(repo, :owner) || repo["owner"]
    name = Map.get(repo, :name) || repo["name"]
    "#{owner}/#{name}"
  end
end
