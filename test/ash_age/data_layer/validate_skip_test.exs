defmodule AshAge.DataLayer.ValidateSkipTest do
  use ExUnit.Case, async: true

  alias AshAge.DataLayer.Info

  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  test "a primary-key attribute in skip fails compilation" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshAge.DataLayer.ValidateSkipTest.SkippedPk do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:vsk_pk)
            repo(AshAge.TestRepo)
            skip([:id])
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end

    assert error.message =~ ":id"
    assert error.message =~ "primary key"
  end

  # refute_dsl_errors is load-bearing: Spark surfaces verifier errors as
  # compiler WARNINGS, so a bare defmodule would still compile if the verifier
  # over-fired on a conforming resource.
  test "skipping a non-PK attribute still compiles (positive control)" do
    refute_dsl_errors do
      defmodule Elixir.AshAge.DataLayer.ValidateSkipTest.Fine do
        use Ash.Resource,
          domain: AshAge.TestDomain,
          validate_domain_inclusion?: false,
          data_layer: AshAge.DataLayer

        age do
          graph(:vsk_ok)
          repo(AshAge.TestRepo)
          skip([:cached])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:cached, :string, public?: true)
        end
      end
    end

    assert Info.skip(AshAge.DataLayer.ValidateSkipTest.Fine) == [:cached]
  end
end
