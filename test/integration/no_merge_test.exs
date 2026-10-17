defmodule AshAge.Integration.NoMergeTest do
  @moduledoc """
  End-to-end tripwire for AGENTS.md rule 2: AGE MERGE has catastrophic
  performance bugs and is banned from EVERY emitted statement. The unit-tier
  never_interpolate_test covers the pure builders; this captures the actual SQL
  Ecto/Postgrex executes for the full CRUD/bulk surface (including statements
  built inline inside callbacks, like do_create's CREATE) via the repo's query
  telemetry, and asserts none of it contains MERGE.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  defmodule Widget do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_no_merge)
      repo(AshAge.TestRepo)
      label(:Widget)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  test "no executed statement for create/read/update/bulk/destroy contains MERGE" do
    queries =
      capture_sql(fn ->
        with_graph(
          "itest_no_merge",
          fn ->
            {:ok, w} = Widget |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
            _ = Ash.read(Widget)
            _ = w |> Ash.Changeset.for_update(:update, %{name: "b"}) |> Ash.update()

            _ =
              Ash.bulk_create([%{name: "c"}, %{name: "d"}], Widget, :create,
                return_records?: false
              )

            :ok = Ash.destroy(w)
          end,
          vlabels: ["Widget"]
        )
      end)

    cypher_statements = Enum.filter(queries, &String.contains?(&1, "ag_catalog.cypher"))
    assert length(cypher_statements) > 0, "no cypher statements captured — tripwire is vacuous"

    for sql <- cypher_statements do
      refute sql =~ "MERGE", "executed statement contains banned MERGE: #{sql}"
    end
  end

  defp capture_sql(fun) do
    parent = self()
    handler_id = "no-merge-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:ash_age, :test_repo, :query]],
      fn _event, _measurements, %{query: query}, _ ->
        send(parent, {:sql, query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:sql, query} -> receive_all([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
