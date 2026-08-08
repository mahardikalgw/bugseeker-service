defmodule Codeseeker.Repo.Migrations.AddMinInlineSeverityToPrReviews do
  use Ecto.Migration

  def change do
    alter table(:pr_reviews) do
      add(:min_inline_severity, :string)
    end
  end
end
