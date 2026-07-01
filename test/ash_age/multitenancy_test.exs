defmodule AshAge.MultitenancyTest do
  use ExUnit.Case, async: true

  # Spark verifier errors raised inside the `@after_verify` hook are converted
  # to stderr diagnostics by Elixir/Spark rather than propagated as exceptions,
  # so `assert_raise` around an inline `defmodule` cannot catch them (Spark
  # documents this in `Spark.Test`). Use Spark's sanctioned collector helpers.
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  describe "ValidateMultitenancyAttr verifier" do
    test "compile fails when the :attribute tenant attribute is in `age do skip`" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:age, :skip]} do
          defmodule Elixir.AshAge.MultitenancyTest.SkippedTenantResource do
            use Ash.Resource,
              domain: AshAge.TestDomain,
              validate_domain_inclusion?: false,
              data_layer: AshAge.DataLayer

            age do
              graph(:verifier_skip_test)
              repo(AshAge.TestRepo)
              skip([:org_id])
            end

            multitenancy do
              strategy(:attribute)
              attribute(:org_id)
            end

            attributes do
              uuid_primary_key(:id)
              attribute(:org_id, :uuid, public?: true)
            end
          end
        end

      assert error.message =~ ~r/must not appear in `age do skip/
    end

    test "compiles cleanly when the :attribute tenant attribute is not skipped" do
      refute_dsl_errors do
        defmodule Elixir.AshAge.MultitenancyTest.CleanTenantResource do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:verifier_clean_test)
            repo(AshAge.TestRepo)
          end

          multitenancy do
            strategy(:attribute)
            attribute(:org_id)
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:org_id, :uuid, public?: true)
          end
        end
      end

      assert Ash.Resource.Info.multitenancy_strategy(AshAge.MultitenancyTest.CleanTenantResource) ==
               :attribute
    end
  end
end
