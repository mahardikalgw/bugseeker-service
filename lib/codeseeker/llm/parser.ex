defmodule Codeseeker.Llm.Parser do
  @moduledoc """
  Parses the LLM's JSON response into a list of `Codeseeker.Reviews.Issue`
  structs, validating enums and applying the skill's severity bias.

  Pure module — the repair round-trip to DeepSeek is orchestrated by the
  caller (the coordinator's `review_file/3`).
  """

  alias Codeseeker.Reviews.Issue
  alias Codeseeker.Skills.{Registry, Skill}

  @doc """
  Parses the raw LLM `content` into issues for `file_path`.

  Invalid items (unknown severity/category) are dropped and logged rather
  than failing the whole file.
  """
  @spec parse(String.t() | nil, String.t(), Skill.t()) ::
          {:ok, [Issue.t()]} | {:error, :unparseable}
  def parse(content, file_path, skill) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        parsed =
          issues
          |> Enum.flat_map(&parse_issue(&1, file_path, skill))
          |> Registry.apply_bias(skill)

        {:ok, parsed}

      {:ok, _other} ->
        {:error, :unparseable}

      {:error, _reason} ->
        {:error, :unparseable}
    end
  end

  def parse(_content, _file_path, _skill), do: {:error, :unparseable}

  defp parse_issue(%{"message" => message} = raw, file_path, skill) do
    severity = raw |> Map.get("severity") |> normalize_enum(&Issue.valid_severity?/1, :severity)
    category = raw |> Map.get("category") |> normalize_enum(&Issue.valid_category?/1, :category)

    if severity && category do
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
          skill: skill.name
        }
      ]
    else
      []
    end
  end

  defp parse_issue(_raw, _file_path, _skill), do: []

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
