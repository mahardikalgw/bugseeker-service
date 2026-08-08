defmodule Codeseeker.RepoConfig do
  @moduledoc """
  Reads the reviewed repository's own `.codeseeker.yml` (or
  `.codeseeker.yaml`) and turns it into review settings.

  Supported keys (all optional):

      agents:
        - nestjs            # framework bundle: all nestjs_* agents
        - nestjs_security   # or individual agents
        - typescript
      min_inline_severity: HIGH

  Precedence: `.codeseeker.yml` in the repo > `Codeseeker.PerRepo`
  (runtime/config overrides) > defaults.

  An `agents` entry without a `_` (e.g. `nestjs`) expands to every loaded
  agent whose name is exactly it or starts with `"<name>_"`. Unknown or
  empty entries are ignored, so a repo can never disable *all* agents by
  accident.
  """

  require Logger

  alias Codeseeker.{Agents.Cache, Clients}

  @paths [".codeseeker.yml", ".codeseeker.yaml"]
  @severities ~w(CRITICAL HIGH MEDIUM LOW INFO)

  @type t :: %{optional(:agents) => [String.t()], optional(:min_inline_severity) => String.t()}

  @doc """
  Fetches and parses the repo's `.codeseeker.yml` at `ref`.

  Returns `nil` when the repo has no config file or the file cannot be
  parsed — callers fall back to `PerRepo` in that case.
  """
  @spec fetch(map(), String.t()) :: t() | nil
  def fetch(repo, ref) do
    # Reduce over candidate paths: the first path that EXISTS wins (even
    # when its content parses to an empty config), so a present-but-minimal
    # file still takes precedence over the next candidate path.
    Enum.reduce_while(@paths, nil, fn path, _acc ->
      case Clients.github().get_raw_contents(repo, path, ref) do
        {:ok, content} ->
          {:halt, parse(content)}

        {:error, :not_found} ->
          {:cont, nil}

        {:error, reason} ->
          Logger.warning("repo config fetch failed", path: path, reason: inspect(reason))
          {:cont, nil}
      end
    end)
  end

  @doc """
  Parses `.codeseeker.yml` content into a config map. Returns `nil` for
  unparseable or non-map content (fail open to PerRepo/defaults).
  """
  @spec parse(String.t()) :: t() | nil
  def parse(content) when is_binary(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> build()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp build(raw) do
    %{}
    |> put_agents(raw["agents"])
    |> put_min_severity(raw["min_inline_severity"])
  end

  defp put_agents(acc, list) when is_list(list) do
    agents =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&expand_agent/1)
      |> Enum.uniq()

    if agents == [], do: acc, else: Map.put(acc, :agents, agents)
  end

  defp put_agents(acc, _), do: acc

  # A bare name ("nestjs") expands to the whole framework bundle
  # ("nestjs_architecture", ...); a full agent name passes through when
  # it exists. Unknown names are dropped.
  defp expand_agent(name) do
    normalized = name |> String.trim() |> String.downcase()

    if Cache.get(normalized) do
      [normalized]
    else
      Cache.all_names()
      |> Enum.filter(&String.starts_with?(&1, normalized <> "_"))
    end
  end

  defp put_min_severity(acc, value) when is_binary(value) do
    severity = String.upcase(String.trim(value))
    if severity in @severities, do: Map.put(acc, :min_inline_severity, severity), else: acc
  end

  defp put_min_severity(acc, _), do: acc
end
