defmodule AshAge.DataLayer.Verifiers.ValidateEdge do
  @moduledoc """
  Raises a `Spark.Error.DslError` at compile verification when an `edge`
  entity's `label` or a `properties` key is not a valid AGE identifier
  (build-blocking under `--warnings-as-errors` — Spark emits verifier errors
  as compiler diagnostics).

  Edge labels are interpolated directly into Cypher (`MATCH (n)-[r:LABEL]->()`).
  Edge property keys have no query-generation consumer yet, but a later task
  will interpolate them the same way `set_clauses/1` handles vertex property
  keys (`SET e.<key> = $<key>`), so they are validated here at declaration time
  rather than deferred to when that path lands.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:age])
    |> Enum.filter(&match?(%AshAge.Edge{}, &1))
    |> Enum.reduce_while(:ok, fn edge, :ok ->
      case Enum.find([edge.label | edge.properties], &(not valid_identifier?(&1))) do
        nil ->
          {:cont, :ok}

        bad ->
          {:halt,
           {:error,
            DslError.exception(
              module: Verifier.get_persisted(dsl_state, :module),
              path: [:age, :edge, edge.name],
              message:
                "edge #{inspect(edge.name)} has an invalid AGE identifier #{inspect(bad)}. " <>
                  "Must start with a letter or underscore and contain only alphanumeric " <>
                  "characters and underscores."
            )}}
      end
    end)
  end

  defp valid_identifier?(atom) when is_atom(atom) do
    Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, Atom.to_string(atom))
  end
end
