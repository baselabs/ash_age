# Race-free upserts with ash_onetime

ash_age's upsert is a **two-statement existence-MATCH-then-CREATE/SET** path,
and AGE has **no unique constraint** to arbitrate identity — so two concurrent
upserts of the same identity can both take the CREATE branch and land two
vertices. That limitation is documented (see `usage-rules.md`), and it is
exactly the class of problem [ash_onetime](https://hex.pm/packages/ash_onetime)
exists to make impossible: PostgreSQL-authoritative, once-per-key admission.

## Why the pairing works

An AGE graph **is PostgreSQL**. When the host reserves an ash_onetime
admission claim in the same transaction that performs the graph write:

- the claim insert is a plain PostgreSQL row insert protected by a **unique
  constraint** — the arbiter AGE lacks;
- a racing retry's claim insert blocks on the winner's uncommitted row and
  returns a typed result (`:request_in_progress`, or the stored response once
  the winner commits) instead of executing a second graph write;
- the claim, the graph write, and the completion commit or **roll back
  together** — a failed host effect takes the claim AND the vertex with it,
  so a retry executes rather than colliding with a phantom claim.

Use the `AshOnetime.Transaction` boundary (admission inside a transaction you
own): `protect` on the resource requires `AshPostgres.DataLayer`, so the
resource-level extension does not apply to ash_age-backed resources — the
Transaction boundary is the composable seam, and it is the documented path for
hosts that already own the authoritative transaction.

## The pattern

```elixir
def create_once(idempotency_key, attrs) do
  MyApp.Repo.transaction(fn ->
    case AshOnetime.Transaction.idempotency(MyApp.Repo,
           # required: a local {module, action} pair, a logical partition,
           # a scope, and the caller-supplied key
           operation: {__MODULE__, :create_item},
           partition: "global",
           scope: "items",
           key: idempotency_key,
           # bind the request: same key + different request is terminal
           fingerprint: :crypto.hash(:sha256, Jason.encode!(attrs)),
           retention_seconds: 3600,
           codec: "raw"
         ) do
      {:execute, admission} ->
        {:ok, item} =
          MyApp.Item
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(upsert?: true)

        # The claim's stored response — replayed VERBATIM on retries:
        {:ok, payload} =
          AshOnetime.Transaction.complete(
            admission,
            Jason.encode!(%{"id" => item.id})
          )

        payload

      {:replay, exact_bytes} ->
        # A completed matching request: replay the stored response, write nothing.
        exact_bytes

      {:error, error} ->
        # e.g. request_in_progress (a concurrent execution holds the key),
        # or key_reused_with_different_request (terminal — never re-executes).
        MyApp.Repo.rollback(error)
    end
  end)
end
```

Requirements: the claim store must be migrated on the same database
(`mix ash_onetime.install`), and the transaction runs `READ COMMITTED` (the
PostgreSQL default) — ash_onetime's documented operating mode.

## What is proven

This exact pattern is pinned by an executable integration test in ash_age's
suite (`test/integration/onetime_upsert_test.exs`, run in CI against live
AGE), which renders ash_onetime's real install migration through
`Ecto.Migrator` — no hand-rolled claim table — and asserts all three
guarantees:

1. **The race**: two concurrent transactions on one key land exactly one
   vertex; the loser is refused at admission or replays.
2. **The replay**: a completed key returns the stored response verbatim and
   lands no new vertex.
3. **The rollback**: a host failure after the graph write removes the claim
   AND the vertex together — the key is fresh for the retry.

## When to reach for this

Any create/upsert where *duplicate execution* would be a data-integrity
event rather than a cosmetic one: payment-like effects, external system
mirrors, anything retried by an at-least-once caller. For plain
"create-or-update by identity" without concurrent retries, the built-in
upsert is fine — reserve the admission machinery for writes that must be
exactly-once.
