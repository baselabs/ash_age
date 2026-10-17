defmodule AshAge.ErrorsTest do
  @moduledoc "Error messages must never leak filtered values or DB row contents."
  use ExUnit.Case, async: true

  alias AshAge.DataLayer
  alias AshAge.Errors.{QueryFailed, UnsupportedFilter, UpdateFailed}
  alias AshAge.Query
  alias AshAge.Query.Filter

  alias Ash.Query.Function.Contains
  alias Ash.Query.Operator.Has
  alias Ash.Query.Ref

  defp q, do: %Query{resource: __MODULE__, graph: :g, label: :L, repo: __MODULE__, params: %{}}
  defp ref(name), do: %Ref{attribute: %{name: name}}

  describe "UnsupportedFilter redaction" do
    test "renders the operator and field, never a value" do
      msg = Exception.message(UnsupportedFilter.exception(operator: Contains, field: :tags))
      assert msg =~ "Contains"
      assert msg =~ "tags"
    end

    test "an unsupported operator's filtered value never reaches the error message" do
      secret = "SSN-123-45-6789"

      # Fragment is genuinely unsupported (contains/starts/ends_with became
      # supported in 2.1.0; this property needs an operator that still rejects).
      {:error, err} =
        Filter.translate(
          %Ash.Query.Function.Fragment{arguments: ["WHERE name = #{secret}"]},
          q()
        )

      refute Exception.message(err) =~ secret
      assert Exception.message(err) =~ "Fragment"
    end

    test "still names the field when Ref.attribute is a bare atom (not a %{name: _} map)" do
      {:error, err} =
        Filter.translate(%Has{left: %Ref{attribute: :name}, right: "x"}, q())

      assert Exception.message(err) =~ "Has"
      assert Exception.message(err) =~ "name"
    end
  end

  describe "redact_db_error/1" do
    test "surfaces the SQLSTATE code but never the value-bearing DETAIL line" do
      err = %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          constraint: "Doc_pkey",
          detail: "Key (ssn)=(123-45-6789) already exists."
        }
      }

      reason = DataLayer.redact_db_error(err)
      refute reason =~ "123-45-6789"
      assert reason =~ "unique_violation"
    end

    test "falls back to a generic reason for a driver/connection error (no postgres map)" do
      assert DataLayer.redact_db_error(%Postgrex.Error{message: "connection refused"}) ==
               "database connection error"
    end

    test "redacts a non-Postgrex error term without leaking its message or crashing" do
      # A connection-level failure surfaces as e.g. %DBConnection.ConnectionError{},
      # not %Postgrex.Error{} — it must still be redacted, never crash the callback.
      reason = DataLayer.redact_db_error(%RuntimeError{message: "SECRET-ssn-999"})

      refute reason =~ "SECRET-ssn-999"
      assert reason == "database error"
    end
  end

  describe "error message structural redaction (a raw driver error never inspects through message/1)" do
    test "QueryFailed.message/1 redacts a %Postgrex.Error{} reason" do
      error =
        QueryFailed.exception(
          query: "AGE read query",
          reason: %Postgrex.Error{postgres: %{code: "42601", message: "SECRET-sql-detail"}}
        )

      msg = Exception.message(error)

      refute msg =~ "SECRET-sql-detail"
      assert msg =~ "database error"
    end

    test "QueryFailed.message/1 still shows an already-redacted binary reason" do
      error =
        QueryFailed.exception(
          query: "AGE read query",
          reason: "database error (23505)"
        )

      assert Exception.message(error) =~ "23505"
    end

    test "UpdateFailed.message/1 redacts a %Postgrex.Error{} reason" do
      error =
        UpdateFailed.exception(
          resource: SomeResource,
          reason: %Postgrex.Error{postgres: %{code: "23505", detail: "SECRET-key=(1)"}}
        )

      msg = Exception.message(error)

      refute msg =~ "SECRET-key"
      assert msg =~ "database error"
    end
  end
end
