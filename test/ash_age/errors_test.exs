defmodule AshAge.ErrorsTest do
  @moduledoc "Error messages must never leak filtered values or DB row contents."
  use ExUnit.Case, async: true

  alias AshAge.DataLayer
  alias AshAge.Errors.UnsupportedFilter
  alias AshAge.Query
  alias AshAge.Query.Filter

  alias Ash.Query.Function.Contains
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

      {:error, err} =
        Filter.translate(%Contains{name: :contains, arguments: [ref(:name), secret]}, q())

      refute Exception.message(err) =~ secret
      assert Exception.message(err) =~ "Contains"
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
  end
end
