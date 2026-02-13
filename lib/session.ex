defmodule AshAge.Session do
  @moduledoc """
  Session setup for Apache AGE connections.

  Configures each PostgreSQL connection with the correct search path and
  loads the AGE extension. This must be called on every new connection
  to ensure AGE functions and types are available.

  ## Usage

  Add to your Repo config:

      config :my_app, MyApp.Repo,
        after_connect: {AshAge.Session, :setup, []}

  This sets the search path to `public, ag_catalog, "$user"` and loads
  the AGE extension via `LOAD 'age'`.

  ### Why the search path order matters

  `public` must come before `ag_catalog` so that Ecto's
  `public.schema_migrations` table is found before AGE's
  `ag_catalog.schema_migrations`, which would otherwise shadow it
  and break Ecto migrations.
  """

  @search_path ~s(public, ag_catalog, "$user")

  @doc """
  Sets up an AGE-ready session on the given database connection.

  Called automatically by Ecto's `after_connect` hook. Sets the
  search path and loads the AGE extension.
  """
  @spec setup(DBConnection.t()) :: :ok
  def setup(conn) do
    setup_search_path(conn)
    load_age_extension(conn)
    :ok
  end

  defp setup_search_path(conn) do
    Postgrex.query!(conn, "SET search_path TO #{@search_path}", [])
  end

  defp load_age_extension(conn) do
    Postgrex.query!(conn, "LOAD 'age'", [])
  end
end
