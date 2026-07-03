defmodule AshAge.Integration.SensitiveSearchTest do
  @moduledoc """
  S7 end-to-end gate: a `sensitive` binary attribute holding deterministic
  ciphertext is equality-searchable through Ash filters (the spec's
  "graph-side-filterable deterministic encryption" claim), with negative
  controls proving the gate can go red: a wrong ciphertext matches nothing,
  range filters are rejected value-free, sort is rejected at query build.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  # NewType wrapper over :binary — spec §6 requires at least one RESOURCE
  # attribute (not just the Cast unit seam) to exercise the storage-type
  # predicate through Info.attribute_types → serialize/coerce/filter end-to-end.
  defmodule CipherText do
    use Ash.Type.NewType, subtype_of: :binary
  end

  defmodule Patient do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_s7_sens
      repo AshAge.TestRepo
      label :Patient
      sensitive([:ssn])
    end

    attributes do
      uuid_primary_key :id
      attribute :ssn, CipherText, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:ssn, :name]
      defaults [:read, :create, :update, :destroy]
    end
  end

  # Deterministic "encryption" simulation: same plaintext -> same ciphertext
  # bytes, guaranteed non-UTF-8 so nothing accidentally treats it as text.
  # (Real apps use AshCloak/Cloak with a deterministic cipher for searchable
  # fields; ash_age only ever sees the bytes.)
  defp det_encrypt(plaintext), do: <<0, 255>> <> :crypto.hash(:sha256, plaintext)

  test "deterministic ciphertext is equality-searchable; wrong ciphertext matches nothing" do
    ct_a = det_encrypt("111-11-1111")
    ct_b = det_encrypt("222-22-2222")
    ct_c = det_encrypt("333-33-3333")

    with_graph(
      "itest_s7_sens",
      fn ->
        {:ok, _} =
          Patient |> Ash.Changeset.for_create(:create, %{ssn: ct_a, name: "a"}) |> Ash.create()

        {:ok, _} =
          Patient |> Ash.Changeset.for_create(:create, %{ssn: ct_b, name: "b"}) |> Ash.create()

        # Third row NOT in the in-list below — an over-matching `in`
        # translation (matching everything) would drag it in and go red.
        {:ok, _} =
          Patient |> Ash.Changeset.for_create(:create, %{ssn: ct_c, name: "c"}) |> Ash.create()

        # POSITIVE: eq on the ciphertext finds exactly the right row
        assert {:ok, [found]} = Patient |> Ash.Query.filter(ssn == ^ct_a) |> Ash.read()
        assert found.name == "a"
        assert found.ssn == ct_a

        # POSITIVE: in-list finds exactly a and b — not the bystander c
        assert {:ok, both} = Patient |> Ash.Query.filter(ssn in ^[ct_a, ct_b]) |> Ash.read()
        assert both |> Enum.map(& &1.name) |> Enum.sort() == ["a", "b"]

        # NEGATIVE CONTROL (tripwire): a wrong ciphertext matches NOTHING —
        # proves the eq above does real work, not matching everything
        wrong = det_encrypt("444-44-4444")
        assert {:ok, []} = Patient |> Ash.Query.filter(ssn == ^wrong) |> Ash.read()
      end,
      vlabels: ["Patient"]
    )
  end

  test "range filters on the sensitive binary attribute are rejected, not silently wrong" do
    ct = det_encrypt("111-11-1111")

    with_graph(
      "itest_s7_sens",
      fn ->
        {:ok, _} =
          Patient |> Ash.Changeset.for_create(:create, %{ssn: ct, name: "a"}) |> Ash.create()

        assert {:error, error} = Patient |> Ash.Query.filter(ssn > ^<<0, 1>>) |> Ash.read()

        message = Exception.message(error)
        assert message =~ "ssn"
        # value-free: the stored ciphertext leaks in neither raw nor base64 form
        refute message =~ Base.encode64(ct)
        refute String.contains?(message, ct)
      end,
      vlabels: ["Patient"]
    )
  end

  test "sort on the sensitive binary attribute is rejected at query build" do
    assert {:error, %Ash.Error.Invalid{errors: errors} = error} =
             Patient |> Ash.Query.sort(ssn: :asc) |> Ash.read()

    # Pinned rejection class: UnsortableField lands on query.errors at build,
    # before any cypher is issued against AGE.
    assert %Ash.Error.Query.UnsortableField{field: :ssn} =
             Enum.find(errors, &match?(%Ash.Error.Query.UnsortableField{}, &1))

    assert Exception.message(error) =~ "ssn"
  end
end
