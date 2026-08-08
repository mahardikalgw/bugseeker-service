defmodule Bugseeker.Repo.Migrations.AddFilesToPrReviews do
  use Ecto.Migration

  def change do
    alter table(:pr_reviews) do
      # Kept files (path + patch) reviewed by the agents, stored once per PR.
      add :files, {:array, :map}
    end
  end
end
