defmodule Bugseeker.Repo do
  @moduledoc "Ecto repository backed by PostgreSQL."
  use Ecto.Repo,
    otp_app: :bugseeker,
    adapter: Ecto.Adapters.Postgres
end
