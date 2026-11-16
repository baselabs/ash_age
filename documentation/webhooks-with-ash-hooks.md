# Graph change events with ash_hooks

[ash_hooks](https://hex.pm/packages/ash_hooks) handles webhooks for Ash in both
directions: it verifies and deduplicates inbound provider webhooks, and it signs
and delivers outbound ones. An ash_age resource is an ordinary Ash resource, so
ash_hooks works with it as it does with any other, and ash_age needs no option
for it. Set up ash_hooks from [its documentation](https://hexdocs.pm/ash_hooks);
[Verify any sender](https://hexdocs.pm/ash_hooks/verify-any-sender.html) covers
inbound providers.

## Edges are part of the action

`AshAge.Changes.CreateEdge` and `AshAge.Changes.DestroyEdge` are `after_action`
changes. They run inside the action's transaction, after the vertex write. Anything
that observes the action's result sees the edge write as part of it, and a rollback
undoes the vertex and the edge together.

## Exactly-once graph effects

An inbound handler runs as ordinary Ash code and can create or update ash_age
resources. When a graph effect must happen exactly once, even if the same webhook
arrives more than once, write it with the
[race-free upsert pattern](idempotent-upserts.md).
