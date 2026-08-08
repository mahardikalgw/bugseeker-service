defmodule Codeseeker.Repo do
  @moduledoc "Ecto repository backed by PostgreSQL."
  use Ecto.Repo,
    otp_app: :codeseeker,
    adapter: Ecto.Adapters.Postgres
end
