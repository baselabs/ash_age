defmodule AshAge.Multitenancy do
  @moduledoc """
  Resolves the AGE graph name for a `:context`-multitenant resource + tenant.

  The resolved name is a Postgres schema (AGE graph), so it must be a valid AGE
  identifier, at most 63 bytes, injective (distinct tenants map to distinct
  graphs — a hard isolation invariant), and deterministic.

  Default two-branch encoder:

    * **pass-through** — a tenant whose stringified form is identifier-body-clean
      (`[A-Za-z0-9_]+`) becomes `"t_" <> tenant`; the `t_` prefix supplies the
      required letter start, so a leading digit (ULID, integer id) is fine. Keeps
      ULID/integer/slug tenants readable.
    * **encode** — any other tenant (hyphens/exotic, e.g. a UUID) becomes
      `"g" <> Base.encode32(tenant, :lower, no-padding)`; alphabet `[a-z2-7]` is
      all valid, the `g` prefix guarantees a letter start, and a 36-byte UUID
      string fits at 59 bytes.

  Injectivity: branch A always starts `t`, branch B always starts `g`, so the two
  namespaces are disjoint; each branch is a constant prefix over an injective
  input. Anything that will not fit 63 bytes fails **closed** with a value-free
  error, steering the host to the `tenant_graph` MFA override. Injectivity is over
  the *stringified* tenant (integer `42` and string `"42"` collide) — harmless in
  a homogeneous tenant space; the MFA is the escape hatch otherwise.
  """
  alias AshAge.DataLayer.Info

  @max_bytes 63
  @identifier_body ~r/\A[A-Za-z0-9_]+\z/
  @identifier_full ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc """
  Returns the AGE graph name for `resource` and `tenant`.

  Uses the resource's `tenant_graph` MFA if configured, otherwise the default
  two-branch encoder. Always returns a valid AGE identifier or raises a
  value-free `ArgumentError` (fail-closed).
  """
  @spec graph_name(Ash.Resource.t(), term()) :: String.t()
  def graph_name(resource, tenant) do
    case Info.tenant_graph(resource) do
      nil -> default_encode(tenant)
      {m, f, a} -> validate_mfa!(apply(m, f, [tenant | a]))
    end
  end

  defp default_encode(tenant) do
    str = to_string(tenant)
    passthrough = "t_" <> str

    cond do
      str == "" ->
        fail_closed!()

      Regex.match?(@identifier_body, str) and byte_size(passthrough) <= @max_bytes ->
        passthrough

      # Only the "dirty"/overflow branch needs base32 — compute it lazily here so
      # the passthrough hot path (ULID/integer/slug tenants) never pays for it.
      true ->
        encoded = "g" <> Base.encode32(str, case: :lower, padding: false)
        if byte_size(encoded) <= @max_bytes, do: encoded, else: fail_closed!()
    end
  end

  # The MFA output is a tenant-derived value; validate it here with a boolean
  # check and raise a REDACTED error rather than routing it through
  # `AshAge.Migration.validate_identifier!/1`, which echoes `inspect(name)`.
  defp validate_mfa!(name) when is_binary(name) do
    if Regex.match?(@identifier_full, name) and byte_size(name) <= @max_bytes do
      name
    else
      raise ArgumentError,
            "the tenant_graph MFA returned an invalid or too-long AGE identifier (value redacted)"
    end
  end

  defp validate_mfa!(_) do
    raise ArgumentError, "the tenant_graph MFA must return a String AGE identifier"
  end

  defp fail_closed! do
    raise ArgumentError,
          "could not derive a valid AGE graph identifier for the tenant within " <>
            "#{@max_bytes} bytes (tenant value redacted); configure a `tenant_graph` " <>
            "MFA for this tenant space"
  end
end
