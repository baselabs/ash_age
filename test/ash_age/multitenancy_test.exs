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

  describe "AshAge.Multitenancy.graph_name/2 default encoder" do
    # A minimal resource with no tenant_graph override → default encoder path.
    defmodule PlainResource do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:mt_encoder_test)
        repo(AshAge.TestRepo)
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    test "UUID string is base32-encoded, fits 63 bytes, valid identifier" do
      name = AshAge.Multitenancy.graph_name(PlainResource, "550e8400-e29b-41d4-a716-446655440000")
      assert String.starts_with?(name, "g")
      assert byte_size(name) <= 63
      assert Regex.match?(~r/\A[a-z][a-z2-7]*\z/, name)
    end

    test "ULID / integer / slug tenants pass through readably" do
      assert AshAge.Multitenancy.graph_name(PlainResource, "01ARZ3NDEKTSV4RRFFQ69G5FAV") ==
               "t_01ARZ3NDEKTSV4RRFFQ69G5FAV"

      assert AshAge.Multitenancy.graph_name(PlainResource, 42) == "t_42"
      assert AshAge.Multitenancy.graph_name(PlainResource, "acme") == "t_acme"
    end

    test "distinct tenants never collide (cross-branch injectivity)" do
      # Injectivity is over the STRINGIFIED tenant (see moduledoc): a homogeneous
      # tenant space never mixes `42` and `"42"`, which intentionally collide.
      # This list stays within one string form per value to exercise cross-branch
      # (t_ vs g) and near-miss cases ("gacme"/"t_x"/"x") without asserting a
      # cross-type property the design does not provide.
      tenants = [
        "550e8400-e29b-41d4-a716-446655440000",
        "550e8400-e29b-41d4-a716-446655440001",
        "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "acme",
        "gacme",
        42,
        "t_x",
        "x"
      ]

      names = Enum.map(tenants, &AshAge.Multitenancy.graph_name(PlainResource, &1))
      assert length(Enum.uniq(names)) == length(names)
    end

    test "the g/t branch prefixes are load-bearing for disjointness" do
      # A UUID (dirty) must take the g-branch; a slug (clean) the t_ branch.
      # If the encode prefix regressed to `t`, the `starts_with "g"` assert fails.
      uuid = AshAge.Multitenancy.graph_name(PlainResource, "550e8400-e29b-41d4-a716-446655440000")
      assert String.starts_with?(uuid, "g")
      refute String.starts_with?(uuid, "t_")
      assert String.starts_with?(AshAge.Multitenancy.graph_name(PlainResource, "acme"), "t_")
    end

    test "over-long / unencodable tenant fails closed with no value in the message" do
      long = String.duplicate("a", 40) <> "-b"

      err =
        assert_raise ArgumentError, fn ->
          AshAge.Multitenancy.graph_name(PlainResource, long)
        end

      refute err.message =~ long
      assert err.message =~ "redacted"
    end

    test "blank tenant fails closed" do
      assert_raise ArgumentError, fn -> AshAge.Multitenancy.graph_name(PlainResource, "") end
    end
  end

  describe "tenant_graph MFA override" do
    defmodule OverrideTenancy do
      def graph_for(tenant), do: "tenant_" <> to_string(tenant)
    end

    defmodule OverrideResource do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:mt_override_test)
        repo(AshAge.TestRepo)
        tenant_graph({AshAge.MultitenancyTest.OverrideTenancy, :graph_for, []})
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    test "Info.tenant_graph reads the configured MFA" do
      assert AshAge.DataLayer.Info.tenant_graph(OverrideResource) ==
               {AshAge.MultitenancyTest.OverrideTenancy, :graph_for, []}
    end

    test "graph_name applies the MFA instead of the default encoder" do
      assert AshAge.Multitenancy.graph_name(OverrideResource, "acme") == "tenant_acme"
    end

    test "an MFA returning an invalid identifier fails closed, redacted" do
      defmodule BadOverride do
        def graph_for(_tenant), do: "has-a-hyphen"
      end

      defmodule BadOverrideResource do
        use Ash.Resource,
          domain: AshAge.TestDomain,
          validate_domain_inclusion?: false,
          data_layer: AshAge.DataLayer

        age do
          graph(:mt_bad_override)
          repo(AshAge.TestRepo)
          tenant_graph({AshAge.MultitenancyTest.BadOverride, :graph_for, []})
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      err =
        assert_raise ArgumentError, fn ->
          AshAge.Multitenancy.graph_name(BadOverrideResource, "acme")
        end

      refute err.message =~ "has-a-hyphen"
      assert err.message =~ "redacted"
    end
  end
end
