defmodule Codeseeker.Reviews.Issue do
  @moduledoc """
  A single issue reported by the LLM for one file of a PR diff.

  `line` refers to the NEW-file line number (right side of the diff),
  or `nil` when the model could not determine it.
  """

  @enforce_keys [:file_path, :severity, :category, :message]
  defstruct [:file_path, :line, :severity, :category, :message, :recommendation, :skill]

  @type t :: %__MODULE__{
          file_path: String.t(),
          line: pos_integer() | nil,
          severity: String.t(),
          category: String.t(),
          message: String.t(),
          recommendation: String.t() | nil,
          skill: String.t() | nil
        }

  @severities ~w(CRITICAL HIGH MEDIUM LOW INFO)
  @categories ~w(security perf bug style arch)

  @doc "Valid severity values, ordered from most to least severe."
  def severities, do: @severities

  @doc "Valid category values."
  def categories, do: @categories

  def valid_severity?(severity), do: severity in @severities
  def valid_category?(category), do: category in @categories

  @doc "0 for CRITICAL, 4 for INFO. Lower rank = more severe."
  def severity_rank(severity), do: Enum.find_index(@severities, &(&1 == severity))

  @doc "True when the issue is at least as severe as `min_severity`."
  def severity_at_least?(%__MODULE__{severity: severity}, min_severity) do
    severity_rank(severity) <= severity_rank(min_severity)
  end
end
