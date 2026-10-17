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
      graph(:itest_nomerge_ban)
      repo(AshAge.TestRepo)
      label(:Widget)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    identities do
      identity(:unique_name, [:name])
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  test "no executed statement for create/read/update/bulk/upsert/destroy contains MERGE" do
    queries =
      capture_sql(fn ->
        with_graph(
          "itest_nomerge_ban",
          fn ->
            # Results are ASSERTED (not discarded): an early failure must not
            # pass the tripwire vacuously.
            {:ok, w} = Widget |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
            assert {:ok, [%{name: "a"}]} = Ash.read(Widget)

            assert {:ok, _} =
                     w |> Ash.Changeset.for_update(:update, %{name: "b"}) |> Ash.update()

            assert %Ash.BulkResult{status: :success} =
                     Ash.bulk_create([%{name: "c"}, %{name: "d"}], Widget, :create,
                       return_records?: false
                     )

            # The upsert path — where MERGE is the natural temptation — runs the
            # two-statement existence MATCH instead. Keyed on the :unique_name
            # identity so the EXISTING record ("b", from the update above) is
            # matched: the UPDATE branch of the upsert runs, not just CREATE.
            assert {:ok, upserted} =
                     Widget
                     |> Ash.Changeset.for_create(:create, %{name: "b"})
                     |> Ash.create(upsert?: true, upsert_identity: :unique_name)

            assert upserted.id == w.id

            assert :ok = Ash.destroy(w)
          end,
          vlabels: ["Widget"]
        )
      end)

    cypher_statements = Enum.filter(queries, &String.contains?(&1, "ag_catalog.cypher"))
    refute cypher_statements == [], "no cypher statements captured — tripwire is vacuous"

    # Case-insensitive, scoped to the Cypher BODY between the dollar-quote
    # fences (the graph name is caller data — a graph literally named
    # "merge_test" must not trip the keyword ban).
    for sql <- cypher_statements do
      body = cypher_body(sql)

      refute String.contains?(String.upcase(body), "MERGE"),
             "executed Cypher contains banned MERGE: #{sql}"
    end
  end

  defp cypher_body(sql) do
    case Regex.run(~r/\$\$(.*?)\$\$/s, sql) do
      [_, body] -> body
      _ -> ""
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
