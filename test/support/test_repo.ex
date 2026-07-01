defmodule AshAge.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :ash_age, adapter: Ecto.Adapters.Postgres
end
