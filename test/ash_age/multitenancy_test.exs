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

    test "rls_guc on a :context resource fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:age, :rls_guc]} do
          defmodule Elixir.AshAge.MultitenancyTest.RlsContextInvalid do
            use Ash.Resource,
              domain: AshAge.TestDomain,
              validate_domain_inclusion?: false,
              data_layer: AshAge.DataLayer

            age do
              graph(:verifier_rls_ctx)
              repo(AshAge.TestRepo)
              rls_guc("ash_age.tenant_id")
            end

            multitenancy do
              strategy(:context)
            end

            attributes do
              uuid_primary_key(:id)
            end
          end
        end

      assert error.message =~ ~r/rls_guc.*:attribute/s
    end

    test "rls_guc with global? true fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:age, :rls_guc]} do
          defmodule Elixir.AshAge.MultitenancyTest.RlsGlobalInvalid do
            use Ash.Resource,
              domain: AshAge.TestDomain,
              validate_domain_inclusion?: false,
              data_layer: AshAge.DataLayer

            age do
              graph(:verifier_rls_global)
              repo(AshAge.TestRepo)
              rls_guc("ash_age.tenant_id")
            end

            multitenancy do
              strategy(:attribute)
              attribute(:org_id)
              global?(true)
            end

            attributes do
              uuid_primary_key(:id)
              attribute(:org_id, :uuid, public?: true)
            end
          end
        end

      assert error.message =~ ~r/rls_guc.*global/s
    end

    test "a binary-storage-typed multitenancy discriminator fails compilation (S7)" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshAge.MultitenancyTest.BinaryTenant do
            use Ash.Resource,
              domain: AshAge.TestDomain,
              validate_domain_inclusion?: false,
              data_layer: AshAge.DataLayer

            age do
              graph(:vmt_bin)
              repo(AshAge.TestRepo)
            end

            multitenancy do
              strategy(:attribute)
              attribute(:tenant_key)
            end

            attributes do
              uuid_primary_key(:id)
              attribute(:tenant_key, :binary, public?: true)
            end
          end
        end

      assert error.message =~ "tenant_key"
      assert error.message =~ "plaintext comparator"
    end

    test "rls_guc with :attribute (non-global) compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.AshAge.MultitenancyTest.RlsAttrValid do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:verifier_rls_ok)
            repo(AshAge.TestRepo)
            rls_guc("ash_age.tenant_id")
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

      assert AshAge.DataLayer.Info.rls_guc(Elixir.AshAge.MultitenancyTest.RlsAttrValid) ==
               "ash_age.tenant_id"
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

  describe "AshAge.tenant_graph/2 public shim" do
    test "returns the same name the encoder produces (provisioning == query time)" do
      assert AshAge.tenant_graph(AshAge.MultitenancyTest.PlainResource, "acme") ==
               AshAge.Multitenancy.graph_name(AshAge.MultitenancyTest.PlainResource, "acme")
    end
  end

  describe "set_tenant/3" do
    test "overwrites the query graph with the resolved tenant graph" do
      query = %AshAge.Query{
        resource: AshAge.MultitenancyTest.PlainResource,
        graph: :mt_encoder_test,
        label: :Plain,
        repo: AshAge.TestRepo
      }

      {:ok, tenanted} =
        AshAge.DataLayer.set_tenant(AshAge.MultitenancyTest.PlainResource, query, "acme")

      assert tenanted.graph == "t_acme"
    end
  end

  describe "write_graph/2 (write-path graph resolution)" do
    test "non-:context resource uses the base graph" do
      assert AshAge.DataLayer.write_graph(AshAge.MultitenancyTest.PlainResource, %{to_tenant: nil}) ==
               {:ok, :mt_encoder_test}
    end
  end

  describe "can?/2 multitenancy capability" do
    test "the data layer advertises multitenancy support" do
      assert AshAge.DataLayer.can?(nil, :multitenancy)
    end

    test "the data layer advertises changeset_filter support" do
      # Without this, Ash.Changeset.filter/2 silently DROPS the tenant/policy
      # scoping filter on update/destroy (the cross-tenant write vuln).
      assert AshAge.DataLayer.can?(nil, :changeset_filter)
    end
  end

  describe "changeset_where/3 fail-closed" do
    test "a nil filter passes through unchanged (non-multitenant / no scoping)" do
      assert AshAge.DataLayer.changeset_where(
               %{filter: nil},
               "n.id = $match_id",
               %{"match_id" => 1}
             ) == {:ok, "n.id = $match_id", %{"match_id" => 1}}
    end

    test "a translatable filter is AND-ed onto the PK match, params preserved" do
      # An Eq operator the read-path translator supports → scoping clause appended,
      # its parameter seeded past the existing match param (counter starts at 2).
      filter = %Ash.Filter{
        resource: nil,
        expression: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: %{name: :org_id}},
          right: "org_a"
        }
      }

      assert {:ok, where, params} =
               AshAge.DataLayer.changeset_where(
                 %{filter: filter},
                 "n.id = $match_id",
                 %{"match_id" => 1}
               )

      assert where == "n.id = $match_id AND n.org_id = $param2"
      assert params == %{"match_id" => 1, "param2" => "org_a"}
    end

    test "an untranslatable filter fails CLOSED (error, never silently unscoped)" do
      # A genuine Ash operator struct the translator has no clause for. The guarantee
      # is: rather than drop the scoping and run an unscoped WHERE, changeset_where
      # surfaces the error so update/destroy return a redacted failure.
      filter = %Ash.Filter{
        resource: nil,
        expression: %Ash.Query.Function.Contains{
          arguments: [%Ash.Query.Ref{attribute: %{name: :name}}, "x"]
        }
      }

      assert match?(
               {:error, _},
               AshAge.DataLayer.changeset_where(%{filter: filter}, "n.id = $match_id", %{})
             )
    end
  end

  describe "write_graph/2 fail-closed for :context" do
    defmodule CtxResource do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:mt_ctx_base)
        repo(AshAge.TestRepo)
      end

      multitenancy do
        strategy(:context)
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    test "a :context write with a nil tenant fails closed (never the base graph)" do
      assert AshAge.DataLayer.write_graph(CtxResource, %{to_tenant: nil}) ==
               {:error, :tenant_required}
    end

    test "a :context write with a blank tenant fails closed" do
      assert AshAge.DataLayer.write_graph(CtxResource, %{to_tenant: ""}) ==
               {:error, :tenant_required}
    end

    test "a :context write with a real tenant resolves the tenant graph" do
      assert AshAge.DataLayer.write_graph(CtxResource, %{to_tenant: "acme"}) == {:ok, "t_acme"}
    end
  end
end
