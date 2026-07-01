defmodule AshAge.Migration do
  @moduledoc """
  Migration helpers for Apache AGE graph database.

  Provides functions to create and drop AGE graphs, labels, and indexes
  within Ecto migrations.

  ## Usage

      defmodule MyApp.Repo.Migrations.CreateAgeGraph do
        use Ecto.Migration
        import AshAge.Migration

        def up do
          create_age_graph("my_graph")
          create_vertex_label("my_graph", "Entity")
          create_edge_label("my_graph", "RELATES_TO")
          create_vertex_index("my_graph", "Entity", "tenant_id")
        end

        def down do
          drop_age_graph("my_graph")
        end
      end
  """

  alias Ecto.Adapters.SQL

  @doc """
  Creates an AGE graph with the given name.

  Idempotent — checks `ag_catalog.ag_graph` before creating.
  """
  @spec create_age_graph(String.t()) :: :ok
  def create_age_graph(graph_name) do
    validate_identifier!(graph_name)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = '#{graph_name}') THEN
        PERFORM ag_catalog.create_graph('#{graph_name}');
      END IF;
    END $$;
    """)

    :ok
  end

  @doc """
  Drops an AGE graph and all its data.
  """
  @spec drop_age_graph(String.t()) :: :ok
  def drop_age_graph(graph_name) do
    validate_identifier!(graph_name)
    execute("SELECT ag_catalog.drop_graph('#{graph_name}', true)")
    :ok
  end

  @doc """
  Creates a vertex label in the given graph.

  Idempotent — checks `ag_catalog.ag_label` before creating.
  """
  @spec create_vertex_label(String.t(), String.t()) :: :ok
  def create_vertex_label(graph_name, label) do
    validate_identifier!(graph_name)
    validate_identifier!(label)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM ag_catalog.ag_label
        WHERE name = '#{label}'
          AND graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = '#{graph_name}')
      ) THEN
        PERFORM ag_catalog.create_vlabel('#{graph_name}', '#{label}');
      END IF;
    END $$;
    """)

    :ok
  end

  @doc """
  Creates an edge label in the given graph.

  Idempotent — checks `ag_catalog.ag_label` before creating.
  """
  @spec create_edge_label(String.t(), String.t()) :: :ok
  def create_edge_label(graph_name, label) do
    validate_identifier!(graph_name)
    validate_identifier!(label)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM ag_catalog.ag_label
        WHERE name = '#{label}'
          AND graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = '#{graph_name}')
      ) THEN
        PERFORM ag_catalog.create_elabel('#{graph_name}', '#{label}');
      END IF;
    END $$;
    """)

    :ok
  end

  @doc """
  Creates an index on a vertex property.

  Uses `ag_catalog.agtype_access_operator()` instead of the `->>` operator
  because `public` comes before `ag_catalog` in the search path.
  """
  @spec create_vertex_index(String.t(), String.t(), String.t()) :: :ok
  def create_vertex_index(graph_name, label, property) do
    validate_identifier!(graph_name)
    validate_identifier!(label)
    validate_identifier!(property)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_#{graph_name}_#{label}_#{property}
    ON #{graph_name}.#{label}
    USING btree (ag_catalog.agtype_access_operator(properties, '#{property}'))
    """)

    :ok
  end

  @doc """
  Creates an index on an edge property.

  Uses `ag_catalog.agtype_access_operator()` instead of the `->>` operator
  because `public` comes before `ag_catalog` in the search path.
  """
  @spec create_edge_index(String.t(), String.t(), String.t()) :: :ok
  def create_edge_index(graph_name, label, property) do
    validate_identifier!(graph_name)
    validate_identifier!(label)
    validate_identifier!(property)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_#{graph_name}_#{label}_#{property}
    ON #{graph_name}.#{label}
    USING btree (ag_catalog.agtype_access_operator(properties, '#{property}'))
    """)

    :ok
  end

  @doc false
  def validate_identifier!(name) when is_binary(name) do
    unless Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, name) do
      raise ArgumentError,
            "invalid AGE identifier: #{inspect(name)}. " <>
              "Must start with a letter or underscore and contain only alphanumeric characters and underscores."
    end

    name
  end

  def validate_identifier!(name) when is_atom(name) do
    validate_identifier!(Atom.to_string(name))
  end

  @doc """
  Idempotently provisions a tenant's AGE graph and its vertex/edge labels at
  runtime (host-invoked in a tenant-onboarding flow, or from a migration).

  Unlike the `create_*` helpers above (which use `Ecto.Migration.execute/1` and
  only run inside a migration), this uses `Ecto.Adapters.SQL.query!/3`, so it
  works at runtime too. `graph_name` and every label are validated as AGE
  identifiers before interpolation — the intended caller derives `graph_name`
  from `AshAge.tenant_graph/2` over adversarial tenant input.

  `opts`:
    * `:vlabels` — vertex labels to create (default `[]`)
    * `:elabels` — edge labels to create (default `[]`)

  Idempotent: guarded by `IF NOT EXISTS` against `ag_catalog`, so re-runs are
  no-ops.
  """
  @spec provision_tenant(module(), String.t(), keyword()) :: :ok
  def provision_tenant(repo, graph_name, opts \\ []) do
    graph = validate_identifier!(graph_name)
    vlabels = opts |> Keyword.get(:vlabels, []) |> Enum.map(&validate_identifier!/1)
    elabels = opts |> Keyword.get(:elabels, []) |> Enum.map(&validate_identifier!/1)

    run(repo, """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = '#{graph}') THEN
        PERFORM ag_catalog.create_graph('#{graph}');
      END IF;
    END $$;
    """)

    Enum.each(vlabels, &run(repo, label_ddl(graph, &1, "create_vlabel")))
    Enum.each(elabels, &run(repo, label_ddl(graph, &1, "create_elabel")))

    :ok
  end

  # Shares the shape of create_vertex_label/create_edge_label but targets a runtime
  # connection. `graph` and `label` are already validate_identifier!-checked.
  defp label_ddl(graph, label, create_fn) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM ag_catalog.ag_label
        WHERE name = '#{label}'
          AND graph = (SELECT graphid FROM ag_catalog.ag_graph WHERE name = '#{graph}')
      ) THEN
        PERFORM ag_catalog.#{create_fn}('#{graph}', '#{label}');
      END IF;
    END $$;
    """
  end

  defp run(repo, sql), do: SQL.query!(repo, sql, [])

  defp execute(sql) do
    Ecto.Migration.execute(sql)
  end
end
