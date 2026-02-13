defmodule AshAge.DataLayer do
  @moduledoc """
  Ash DataLayer for Apache AGE graph database.

  Stores Ash resources as vertices in an AGE graph within PostgreSQL.
  Uses the existing Ecto.Repo connection pool — no new database driver.
  All dynamic values use parameterized queries for safety.

  ## DSL

  ```elixir
  use Ash.Resource,
    data_layer: AshAge.DataLayer

  age do
    graph :my_graph
    repo MyApp.Repo
    label :MyLabel   # optional, defaults to module short module name
    skip [:computed]  # optional, properties to exclude from AGE

    edge :related_to do
      label :RELATES_TO
      direction :outgoing
      destination MyApp.OtherResource
    end
  end
  ```
  """

  require Spark.Dsl
  require Spark.Dsl.Entity

  @age %Spark.Dsl.Section{
    name: :age,
    describe: "Configuration for the AGE graph data layer",
    schema: [
      graph: [
        type: :atom,
        required: true,
        doc: "The AGE graph name (must be a valid identifier)"
      ],
      repo: [
        type: :atom,
        required: true,
        doc: "The Ecto.Repo module to use for database access"
      ],
      label: [
        type: {:or, [:atom, :string]},
        doc: "Vertex label in the graph. Defaults to the resource's short module name."
      ],
      skip: [
        type: {:list, :atom},
        default: [],
        doc: "List of attribute names to exclude from AGE vertex properties"
      ]
    ],
    entities: [
      %Spark.Dsl.Entity{
        name: :edge,
        describe: "Defines an edge mapping from this vertex to another",
        args: [:name],
        target: AshAge.Edge,
        schema: [
          name: [
            type: :atom,
            required: true,
            doc: "Relationship name (must match an Ash relationship)"
          ],
          label: [
            type: :atom,
            required: true,
            doc: "Edge label in the graph (e.g., :RELATES_TO)"
          ],
          direction: [
            type: {:one_of, [:outgoing, :incoming, :both]},
            default: :outgoing,
            doc: "Edge direction"
          ],
          destination: [
            type: :atom,
            required: true,
            doc: "Destination resource module"
          ]
        ]
      }
    ]
  }

  @behaviour Ash.DataLayer

  alias Ash.Error.Query.NotFound
  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer.Info
  alias AshAge.Errors.{CreateFailed, QueryFailed, UpdateFailed}
  alias AshAge.Query.Filter
  alias AshAge.Type.{Agtype, Cast}
  alias Ecto.Adapters.SQL

  use Spark.Dsl.Extension,
    sections: [@age],
    transformers: [
      AshAge.DataLayer.Transformers.ValidateGraph,
      AshAge.DataLayer.Transformers.EnsureLabelled,
      AshAge.DataLayer.Transformers.ValidateLabelFormat,
      AshAge.DataLayer.Transformers.DefaultRelate
    ]

  # === Capability Declarations ===

  @impl true
  def can?(_, :read), do: true
  def can?(_, :create), do: true
  def can?(_, :update), do: true
  def can?(_, :destroy), do: true
  def can?(_, :transact), do: true
  def can?(_, :filter), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :nested_expressions), do: true
  def can?(_, :sort), do: true
  def can?(_, {:sort, _}), do: true
  def can?(_, {:filter_operator, :eq}), do: true
  def can?(_, {:filter_operator, :not_eq}), do: true
  def can?(_, {:filter_operator, :gt}), do: true
  def can?(_, {:filter_operator, :lt}), do: true
  def can?(_, {:filter_operator, :gte}), do: true
  def can?(_, {:filter_operator, :lte}), do: true
  def can?(_, {:filter_operator, :in}), do: true
  def can?(_, {:filter_operator, :is_nil}), do: true
  def can?(_, {:filter_operator, _}), do: false
  def can?(_, {:filter_expr, %Ash.Query.Operator.Eq{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.NotEq{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.In{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.IsNil{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.GreaterThan{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.LessThan{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.GreaterThanOrEqual{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.LessThanOrEqual{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.BooleanExpression{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Not{}}), do: true
  def can?(_, {:filter_expr, _}), do: false
  def can?(_, :upsert), do: false
  def can?(_, :bulk_create), do: false
  def can?(_, {:lateral_join, _}), do: false
  def can?(_, {:aggregate, _}), do: false
  def can?(_, :multitenancy), do: false
  def can?(_, _), do: false

  # === Required Callbacks ===

  @impl true
  def resource_to_query(resource, _domain) do
    graph = Info.graph(resource)
    label = Info.label(resource)
    repo = Info.repo(resource)

    %AshAge.Query{resource: resource, graph: graph, label: label, repo: repo}
  end

  @impl true
  def run_query(%AshAge.Query{} = query, resource) do
    {cypher, params} = AshAge.Query.to_cypher(query)

    result =
      if map_size(params) > 0 do
        {sql, pg_params} = Parameterized.build(query.graph, cypher, params)
        SQL.query(query.repo, sql, pg_params)
      else
        {sql, pg_params} = Parameterized.build_static(query.graph, cypher)
        SQL.query(query.repo, sql, pg_params)
      end

    case result do
      {:ok, %{rows: rows}} ->
        attribute_map = Info.attribute_map(resource)
        attribute_types = Info.attribute_types(resource)

        records =
          Enum.map(rows, fn [agtype_text] ->
            vertex = Agtype.decode(agtype_text)

            attrs =
              Cast.vertex_to_resource_attrs(vertex, attribute_map, attribute_types)

            struct(resource, attrs)
          end)

        {:ok, records}

      {:error, %Postgrex.Error{} = error} ->
        {:error,
         QueryFailed.exception(
           query: "AGE read query",
           reason: Exception.message(error)
         )}
    end
  end

  # === CRUD Callbacks ===

  @impl true
  def create(resource, changeset) do
    repo = Info.repo(resource)
    graph = Info.graph(resource)
    label = Info.label(resource)

    props = changeset_to_properties(resource, changeset)

    # AGE does NOT support CREATE (n:Label $props) — properties as a parameter
    # map in CREATE is not supported. Must use CREATE + SET pattern instead.
    set_clauses =
      props
      |> Map.keys()
      |> Enum.map_join(", ", fn key -> "n.#{key} = $#{key}" end)

    cypher =
      if set_clauses == "" do
        "CREATE (n:#{label}) RETURN n"
      else
        "CREATE (n:#{label}) SET #{set_clauses} RETURN n"
      end

    {sql, pg_params} = Parameterized.build(graph, cypher, props)

    case SQL.query(repo, sql, pg_params) do
      {:ok, %{rows: [[vertex_text]]}} ->
        attribute_map = Info.attribute_map(resource)
        attribute_types = Info.attribute_types(resource)

        attrs =
          vertex_text
          |> Agtype.decode()
          |> Cast.vertex_to_resource_attrs(attribute_map, attribute_types)

        {:ok, struct(resource, attrs)}

      {:error, %Postgrex.Error{} = error} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: Exception.message(error)
         )}
    end
  end

  @impl true
  def update(resource, changeset) do
    repo = Info.repo(resource)
    graph = Info.graph(resource)
    label = Info.label(resource)

    id = Ash.Changeset.get_attribute(changeset, :id)
    changed_attrs = changeset_to_properties(resource, changeset)

    set_clauses =
      changed_attrs
      |> Map.keys()
      |> Enum.map_join(", ", fn key -> "n.#{key} = $#{key}" end)

    cypher = """
    MATCH (n:#{label})
    WHERE n.id = $match_id
    SET #{set_clauses}
    RETURN n
    """

    params = Map.put(changed_attrs, "match_id", id)
    {sql, pg_params} = Parameterized.build(graph, cypher, params)

    case SQL.query(repo, sql, pg_params) do
      {:ok, %{rows: [[vertex_text]]}} ->
        attribute_map = Info.attribute_map(resource)
        attribute_types = Info.attribute_types(resource)

        attrs =
          vertex_text
          |> Agtype.decode()
          |> Cast.vertex_to_resource_attrs(attribute_map, attribute_types)

        {:ok, struct(resource, attrs)}

      {:ok, %{rows: []}} ->
        {:error, NotFound.exception(resource: resource)}

      {:error, %Postgrex.Error{} = error} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason: Exception.message(error)
         )}
    end
  end

  @impl true
  def destroy(resource, changeset) do
    repo = Info.repo(resource)
    graph = Info.graph(resource)
    label = Info.label(resource)

    id = Ash.Changeset.get_attribute(changeset, :id)

    cypher = """
    MATCH (n:#{label})
    WHERE n.id = $match_id
    DETACH DELETE n
    """

    {sql, pg_params} =
      Parameterized.build(graph, cypher, %{"match_id" => id}, [{:n, :agtype}])

    case SQL.query(repo, sql, pg_params) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{} = error} ->
        {:error,
         QueryFailed.exception(
           query: "AGE delete query",
           reason: Exception.message(error)
         )}
    end
  end

  # === Transaction Support ===

  @impl true
  def transaction(resource, fun, _timeout \\ nil, _reason \\ nil) do
    repo = Info.repo(resource)
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(repo, :transaction, [fun])
  end

  @impl true
  def in_transaction?(resource) do
    repo = Info.repo(resource)
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(repo, :in_transaction?, [])
  end

  # === Filter/Sort/Limit/Offset ===

  @impl true
  def filter(query, filter, _resource) do
    case Filter.translate(filter, query) do
      {:ok, query, where_clause} ->
        {:ok, %{query | filters: query.filters ++ [where_clause]}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def sort(query, sort, _resource) do
    sort_clauses =
      Enum.map(sort, fn
        {%Ash.Resource.Attribute{name: name}, direction} -> {name, direction}
        {name, direction} when is_atom(name) -> {name, direction}
      end)

    {:ok, %{query | sort: query.sort ++ sort_clauses}}
  end

  @impl true
  def limit(query, limit, _resource) do
    {:ok, %{query | limit: limit}}
  end

  @impl true
  def offset(query, offset, _resource) do
    {:ok, %{query | offset: offset}}
  end

  # === Helpers ===

  defp changeset_to_properties(resource, changeset) do
    skip = Info.skip(resource)

    changeset.attributes
    |> Enum.reject(fn {key, _} -> key in skip end)
    |> Enum.map(fn {key, value} ->
      {Atom.to_string(key), serialize_value(value)}
    end)
    |> Map.new()
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp serialize_value(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize_value(value), do: value
end
