defmodule AshAge.DataLayer.ValidateSensitiveTest do
  use ExUnit.Case, async: true

  alias AshAge.DataLayer.Info

  import Spark.Test, only: [assert_dsl_error: 2]

  # POSITIVE CONTROL: a conforming classification compiles (binary attr,
  # skipped attr, binary-typed edge-property argument).
  test "a conforming sensitive declaration compiles" do
    defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.Good do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:vs_good)
        repo(AshAge.TestRepo)
        skip([:derived])
        sensitive([:ssn, :derived])
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:ssn, :binary, public?: true)
        attribute(:derived, :string, public?: true)
      end

      actions do
        defaults([:read])
      end
    end

    assert Info.sensitive(AshAge.DataLayer.ValidateSensitiveTest.Good) == [:ssn, :derived]
  end

  test "R1: an unknown attribute name in sensitive fails compilation" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.Typo do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:vs_typo)
            repo(AshAge.TestRepo)
            sensitive([:ssnn])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:ssn, :binary, public?: true)
          end
        end
      end

    assert error.message =~ "ssnn"
    assert error.message =~ "not a declared attribute"
  end

  test "R2: a plaintext (non-binary-storage, non-skipped) sensitive attribute fails" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.Plain do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:vs_plain)
            repo(AshAge.TestRepo)
            sensitive([:ssn])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:ssn, :string, public?: true)
          end
        end
      end

    assert error.message =~ "ssn"
    assert error.message =~ "binary-storage-typed or listed in `skip`"
  end

  test "R2: an {:array, :binary} sensitive attribute fails (arrays are not binary storage)" do
    # binary_storage?({:array, :binary}) is deliberately false (elements are
    # never tagged; the JSON substrate cannot hold raw bytes in lists) — R2 must
    # reject a sensitive array-of-binary rather than let it store untagged.
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.ArrayBin do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:vs_array_bin)
            repo(AshAge.TestRepo)
            sensitive([:hashes])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:hashes, {:array, :binary}, public?: true)
          end
        end
      end

    assert error.message =~ "hashes"
    assert error.message =~ "binary-storage-typed or listed in `skip`"
  end

  test "R3: the multitenancy discriminator cannot be sensitive" do
    # tenant_id is deliberately :string — a :binary discriminator would ALSO trip
    # ValidateMultitenancyAttr's binary-discriminator rule (Task 11), and
    # assert_dsl_error returns the FIRST matching error in verifier order, which
    # would be the wrong one. The path pin below is belt-and-braces for the same
    # reason. R3 runs before R2 in the verifier's with-chain, so a :string
    # sensitive discriminator still fails on R3, not R2.
    error =
      assert_dsl_error %Spark.Error.DslError{path: [:age, :sensitive]} do
        defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.TenantSens do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:vs_tenant)
            repo(AshAge.TestRepo)
            sensitive([:tenant_id])
          end

          multitenancy do
            strategy(:attribute)
            attribute(:tenant_id)
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:tenant_id, :string, public?: true)
          end
        end
      end

    assert error.message =~ "tenant_id"
    assert error.message =~ "plaintext selector by design"
  end

  test "R4: an edge property named after a sensitive attribute requires binary-typed arguments" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.EdgeLeak do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:vs_edge)
            repo(AshAge.TestRepo)
            sensitive([:ssn])

            edge :rel do
              label(:REL)
              destination(__MODULE__)
              properties([:ssn])
            end
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:ssn, :binary, public?: true)
          end

          relationships do
            has_many(:rel, __MODULE__, destination_attribute: :id)
          end

          actions do
            defaults([:read])

            create :create do
              argument(:ssn, :string)
            end
          end
        end
      end

    assert error.message =~ "ssn"
    assert error.message =~ "binary-storage-typed declared action argument"
  end

  test "R4 passes when the same-named argument is binary-typed" do
    defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.EdgeOk do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:vs_edge_ok)
        repo(AshAge.TestRepo)
        sensitive([:ssn])

        edge :rel do
          label(:REL)
          destination(__MODULE__)
          properties([:ssn])
        end
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:ssn, :binary, public?: true)
      end

      relationships do
        has_many(:rel, __MODULE__, destination_attribute: :id)
      end

      actions do
        defaults([:read])

        create :create do
          argument(:ssn, :binary)
        end
      end
    end

    assert Info.sensitive(AshAge.DataLayer.ValidateSensitiveTest.EdgeOk) == [:ssn]
  end

  # R4 boundary: with NO declared same-named argument, the verifier passes by
  # design — a compile-time check cannot see runtime-injected (set_argument)
  # values. The runtime half of R4 lives in AshAge.Changes.CreateEdge
  # (edge_properties/2 fails closed on a sensitive key without a binary-storage
  # declared argument) — landed as the next task in this slice.
  test "R4 boundary: edge property naming a sensitive attr with zero declared args compiles" do
    defmodule Elixir.AshAge.DataLayer.ValidateSensitiveTest.EdgeNoArgs do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:vs_edge_noargs)
        repo(AshAge.TestRepo)
        sensitive([:ssn])

        edge :rel do
          label(:REL)
          destination(__MODULE__)
          properties([:ssn])
        end
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:ssn, :binary, public?: true)
      end

      relationships do
        has_many(:rel, __MODULE__, destination_attribute: :id)
      end

      actions do
        defaults([:read])
      end
    end

    assert Info.sensitive(AshAge.DataLayer.ValidateSensitiveTest.EdgeNoArgs) == [:ssn]
  end
end
