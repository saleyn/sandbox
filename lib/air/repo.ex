defmodule Air.Repo do
  use Ecto.Repo,
    otp_app: :air,
    adapter: Ecto.Adapters.Postgres
end
