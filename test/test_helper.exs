# Start the test Repo only when a live AGE database is configured via
# AGE_DATABASE_URL; otherwise exclude :integration-tagged tests so the pure-unit
# suite runs anywhere with no database. CI sets AGE_DATABASE_URL on the test job.
if System.get_env("AGE_DATABASE_URL") do
  {:ok, _} = AshAge.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(AshAge.TestRepo, :manual)
  ExUnit.start()
else
  ExUnit.start(exclude: [:integration])
end
