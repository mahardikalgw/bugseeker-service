defmodule Bugseeker.Repo.Migrations.CreatePrReviewsAndReviewIssues do
  use Ecto.Migration

  def change do
    create table(:pr_reviews, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :github_repo_id, :bigint, null: false
      add :owner, :string, null: false
      add :name, :string, null: false
      add :installation_id, :bigint, null: false
      add :pr_number, :integer, null: false
      add :head_sha, :string, null: false
      add :base_sha, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :guidelines, :text
      add :total_files, :integer, default: 0
      add :files_reviewed, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pr_reviews, [:github_repo_id, :pr_number, :head_sha], name: :pr_reviews_unique_head)
    create index(:pr_reviews, [:status])
    create index(:pr_reviews, [:installation_id])

    create table(:review_issues, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :pr_review_id, references(:pr_reviews, on_delete: :delete_all, type: :bigint), null: false
      add :file_path, :string, null: false
      add :line, :integer
      add :severity, :string, null: false
      add :category, :string, null: false
      add :skill_used, :string, null: false
      add :message, :text, null: false
      add :recommendation, :text
      add :posted, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_issues, [:pr_review_id])
    create index(:review_issues, [:pr_review_id, :posted])
    create index(:review_issues, [:severity])
  end
end
