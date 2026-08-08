defmodule Bugseeker.Llm.Parser do
  @moduledoc """
  Parses the LLM's JSON response into a list of `Bugseeker.Reviews.Issue`
  structs, validating enums and applying the agent's severity bias.
  """

  alias Bugseeker.Agents
  alias Bugseeker.Agents.Agent
  alias Bugseeker.Reviews.Issue

  @doc """
  Parses the raw LLM `content` into issues.

  `default_file_path` is used when an item has no `file_path` (per-file
  output); for agents it is `nil` and each item must supply its own.
  Invalid items (unknown severity/category, or no file_path) are dropped.

  Agent severity bias is applied to the parsed issues.
  """
  @spec parse(String.t() | nil, String.t() | nil, Agent.t()) ::
          {:ok, [Issue.t()]} | {:error, :unparseable}
  def parse(content, file_path, agent) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        parsed =
          issues
          |> Enum.flat_map(&parse_issue(&1, file_path, agent))
          |> Agents.apply_bias(agent)

        {:ok, parsed}

      {:ok, _other} ->
        {:error, :unparseable}

      {:error, _reason} ->
        {:error, :unparseable}
    end
  end

  def parse(_content, _file_path, _agent), do: {:error, :unparseable}

  defp parse_issue(%{"message" => message} = raw, default_file_path, agent) do
    severity = raw |> Map.get("severity") |> normalize_enum(&Issue.valid_severity?/1, :severity)
    category = raw |> Map.get("category") |> normalize_enum(&Issue.valid_category?/1, :category)

    file_path =
      case raw["file_path"] do
        fp when is_binary(fp) and fp != "" -> fp
        _ -> default_file_path
      end

    if severity && category && file_path do
      line =
        case raw["line"] do
          line when is_integer(line) and line > 0 -> line
          _ -> nil
        end

      [
        %Issue{
          file_path: file_path,
          line: line,
          severity: severity,
          category: category,
          message: message,
          recommendation: raw["recommendation"],
          agent: agent.name
        }
      ]
    else
      []
    end
  end

  defp parse_issue(_raw, _file_path, _agent), do: []

  defp normalize_enum(nil, _valid?, _kind), do: nil

  defp normalize_enum(value, valid?, kind) do
    normalized =
      case kind do
        :severity -> value |> to_string() |> String.upcase()
        :category -> value |> to_string() |> String.downcase()
      end

    if valid?.(normalized), do: normalized, else: nil
  end
end
