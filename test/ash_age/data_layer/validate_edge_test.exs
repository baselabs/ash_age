defmodule AshAge.DataLayer.ValidateEdgeTest do
  use ExUnit.Case, async: true

  # Spark verifier errors raised inside the `@after_verify` hook are converted
  # to stderr diagnostics by Elixir/Spark rather than propagated as exceptions,
  # so `assert_raise` around an inline `defmodule` cannot catch them (Spark
  # documents this in `Spark.Test`; see also AshAge.MultitenancyTest). Use
  # Spark's sanctioned collector helpers.
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  test "compile fails when an edge label is not a valid AGE identifier" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshAge.DataLayer.ValidateEdgeTest.BadEdgeLabel do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:ve_test)
            repo(AshAge.TestRepo)

            edge :rel do
              label(:"bad-label")
              destination(__MODULE__)
            end
          end

          attributes do
            uuid_primary_key(:id)
          end

          relationships do
            has_many(:rel, __MODULE__, destination_attribute: :id)
          end
        end
      end

    assert error.message =~ "invalid AGE identifier"
    # The verifier interpolates `inspect(bad)`, so the offending value appears
    # verbatim — pins the failure to THIS edge's label, not the other branch.
    assert error.message =~ "bad-label"
  end

  test "compile fails when an edge property key is not a valid AGE identifier" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshAge.DataLayer.ValidateEdgeTest.BadEdgeProperty do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:ve_prop_test)
            repo(AshAge.TestRepo)

            edge :rel do
              label(:RELATES)
              destination(__MODULE__)
              properties([:"bad-key"])
            end
          end

          attributes do
            uuid_primary_key(:id)
          end

          relationships do
            has_many(:rel, __MODULE__, destination_attribute: :id)
          end
        end
      end

    assert error.message =~ "invalid AGE identifier"
    # The verifier interpolates `inspect(bad)`, so the offending value appears
    # verbatim — pins the failure to THIS edge's property key, not the label.
    assert error.message =~ "bad-key"
  end

  test "compiles with a valid edge + properties" do
    refute_dsl_errors do
      defmodule Elixir.AshAge.DataLayer.ValidateEdgeTest.GoodEdge do
        use Ash.Resource,
          domain: AshAge.TestDomain,
          validate_domain_inclusion?: false,
          data_layer: AshAge.DataLayer

        age do
          graph(:ve_good)
          repo(AshAge.TestRepo)

          edge :rel do
            label(:RELATES)
            destination(__MODULE__)
            properties([:weight])
          end
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          has_many(:rel, __MODULE__, destination_attribute: :id)
        end
      end
    end

    [edge] = AshAge.DataLayer.Info.edges(AshAge.DataLayer.ValidateEdgeTest.GoodEdge)
    assert edge.label == :RELATES
    assert edge.properties == [:weight]
  end
end
