defmodule Codeseeker.Reviews.PrReview do
  @moduledoc """
  One review run for a PR at a specific `head_sha`. The unique
  `(github_repo_id, pr_number, head_sha)` index is the idempotency key:
  GitHub redelivering the same webhook cannot create a second run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending processing completed failed)

  schema "pr_reviews" do
    field(:github_repo_id, :integer)
    field(:owner, :string)
    field(:name, :string)
    field(:installation_id, :integer)
    field(:pr_number, :integer)
    field(:head_sha, :string)
    field(:base_sha, :string)
    field(:status, :string, default: "pending")
    field(:guidelines, :string)
    field(:files, {:array, :map})
    field(:total_files, :integer, default: 0)
    field(:files_reviewed, :integer, default: 0)

    has_many(:issues, Codeseeker.Reviews.ReviewIssue, on_replace: :delete)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(pr_review, attrs) do
    pr_review
    |> cast(attrs, [
      :github_repo_id,
      :owner,
      :name,
      :installation_id,
      :pr_number,
      :head_sha,
      :base_sha,
      :status,
      :guidelines,
      :files,
      :total_files,
      :files_reviewed
    ])
    |> validate_required([
      :github_repo_id,
      :owner,
      :name,
      :installation_id,
      :pr_number,
      :head_sha
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:pr_reviews_unique_head,
      name: :pr_reviews_unique_head,
      message: "already reviewed this head_sha"
    )
  end

  @doc "Changeset that only updates the status (used to advance the state machine)."
  def status_changeset(pr_review, status) do
    pr_review
    |> change(status: status)
    |> validate_inclusion(:status, @statuses)
  end
end
