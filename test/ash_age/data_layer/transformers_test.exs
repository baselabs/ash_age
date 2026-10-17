defmodule AshAge.DataLayer.TransformersTest do
  @moduledoc """
  Coverage for the age-DSL compile-time transformers: ValidateGraph (graph
  name is a valid AGE identifier), ValidateLabelFormat (label likewise), and
  EnsureLabelled (label defaults to the resource module's short name when not
  configured). AGENTS.md's "Adding DSL Configuration" recipe has pointed at
  this file since S3 — it now exists.
  """
  use ExUnit.Case, async: true

  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  alias AshAge.DataLayer.Info

  describe "ValidateGraph" do
    test "a graph name that is not a valid AGE identifier fails compilation" do
      # Transformer DslErrors RAISE out of the defmodule (they are not downgraded
      # like verifier errors), so assert_raise is the collector here.
      assert_raise Spark.Error.DslError, ~r/Invalid graph name/, fn ->
        defmodule Elixir.AshAge.DataLayer.TransformersTest.BadGraph do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:"bad-graph")
            repo(AshAge.TestRepo)
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end
    end

    test "a valid graph name compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.AshAge.DataLayer.TransformersTest.GoodGraph do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:tx_good_graph)
            repo(AshAge.TestRepo)
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end
    end
  end

  describe "ValidateLabelFormat" do
    test "a label that is not a valid AGE identifier fails compilation" do
      # Unlike ValidateGraph (early pass, collector-visible), this transformer
      # runs after EnsureLabelled and its DslError RAISES out of the defmodule.
      assert_raise Spark.Error.DslError, ~r/Invalid label/, fn ->
        defmodule Elixir.AshAge.DataLayer.TransformersTest.BadLabel do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:tx_label_graph)
            repo(AshAge.TestRepo)
            label(:"1bad")
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end
    end
  end

  describe "EnsureLabelled" do
    test "label defaults to the resource module's short name when not configured" do
      refute_dsl_errors do
        defmodule Elixir.AshAge.DataLayer.TransformersTest.AutoLabelled do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:tx_auto_label)
            repo(AshAge.TestRepo)
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end

      assert to_string(Info.label(Elixir.AshAge.DataLayer.TransformersTest.AutoLabelled)) ==
               "AutoLabelled"
    end

    test "an explicitly-configured label is kept as-is" do
      refute_dsl_errors do
        defmodule Elixir.AshAge.DataLayer.TransformersTest.CustomLabelled do
          use Ash.Resource,
            domain: AshAge.TestDomain,
            validate_domain_inclusion?: false,
            data_layer: AshAge.DataLayer

          age do
            graph(:tx_custom_label)
            repo(AshAge.TestRepo)
            label(:Custom)
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end

      assert to_string(Info.label(Elixir.AshAge.DataLayer.TransformersTest.CustomLabelled)) ==
               "Custom"
    end
  end
end
