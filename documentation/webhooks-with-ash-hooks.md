# Graph change events with ash_hooks

[ash_hooks](https://hex.pm/packages/ash_hooks) is webhooks for Ash, in both
directions — inbound provider webhooks (signature verification, ledger-based
deduplication, at-least-once handlers) and outbound delivery (Standard
Webhooks signing, retries, backoff, dead-lettering). It operates at the
**action level**; ash_age is the **storage** underneath — so the two compose
with zero integration code. Nothing on this page requires any ash_age option:
an ash_age-backed resource is an Ash resource like any other.

## Outbound: announce graph changes

Register hooks on the resource's actions; every create/update/destroy of a
vertex (or an edge-carrying action) emits a signed webhook through the
delivery path you configured for ash_hooks:

```elixir
defmodule MyApp.Entity do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshAge.DataLayer,
    extensions: [AshHooks]

  age do
    graph :my_graph
    repo MyApp.Repo
  end

  hooks do
    webhook :entity_created do
      action :create
      # url / signing / payload shape per the ash_hooks DSL
    end

    webhook :entity_deleted do
      action :destroy
    end
  end

  # ...attributes/actions as usual
end
```

Edge actions compose the same way: `AshAge.Changes.CreateEdge` /
`DestroyEdge` are `after_action` changes inside the action's transaction, so
a hook on that action fires with the vertex's final state after the edge
write — one webhook per action, edge included in the effect.

## Delivery guarantees and the graph

- Handlers/deliveries run at-least-once with retries and dead-lettering —
  treat receivers accordingly (idempotent by event id, as ash_hooks' outbound
  envelope provides).
- Webhook delivery is asynchronous to the action; the graph write's
  transaction is not held open by delivery (that's ash_hooks' contract, not
  ash_age's).

## Inbound: graph effects from provider webhooks

The inbound half (verify → dedup on the ledger → run your handler) pairs well
with graph writes: the handler runs as ordinary Ash code and can create or
update ash_age-backed resources. For effects that must be exactly-once in the
graph, combine with the [race-free upsert pattern](idempotent-upserts.html):
the inbound ledger dedups *deliveries*, while admission keys dedup *effects* —
at-least-once delivery into exactly-once graph writes.

## One caveat

If an outbound webhook fires from inside an action whose transaction later
rolls back, the event describes a write that never landed — prefer ash_hooks'
own post-commit delivery configuration for events that assert graph state, the
same way you would with Ash notifications.
