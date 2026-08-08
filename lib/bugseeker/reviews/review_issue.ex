defmodule Bugseeker.Reviews.ReviewIssue do
  @moduledoc """
  A single issue found for a file of a PR review. Stored so the aggregate
  job can post a complete review even after many parallel file jobs finish,
  and as an audit trail.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "review_issues" do
    field(:pr_review_id, :integer, primary_key: false)
    field(:file_path, :string)
    field(:line, :integer)
    field(:severity, :string)
    field(:category, :string)
    field(:skill_used, :string)
    field(:message, :string)
    field(:recommendation, :string)
    field(:posted, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :pr_review_id,
      :file_path,
      :line,
      :severity,
      :category,
      :skill_used,
      :message,
      :recommendation,
      :posted
    ])
    |> validate_required([:pr_review_id, :file_path, :severity, :category, :skill_used, :message])
  end
end
