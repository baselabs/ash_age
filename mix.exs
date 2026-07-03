defmodule AshAge.MixProject do
  use Mix.Project

  @version "0.2.6"
  @source_url "https://github.com/baselabs/ash_age"

  def project do
    [
      app: :ash_age,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      name: "AshAge",
      description: "Ash Framework DataLayer for Apache AGE graph database",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.watch": :test,
        credo: :test,
        dialyzer: :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime dependencies
      {:ash, "~> 3.11"},
      {:splode, "~> 0.3"},
      {:spark, ">= 2.3.3 and < 3.0.0-0"},
      {:jason, "~> 1.2"},
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry, "~> 1.0"},

      # Dev/Test dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* usage-rules.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      # The changelog references internal and historical functions by name;
      # those are expected not to resolve as hexdocs links.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      extras: [
        "README.md",
        "usage-rules.md",
        "documentation/troubleshooting.md",
        "documentation/dsls/DSL-AshAge.DataLayer.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ["documentation/troubleshooting.md"],
        Reference: ["documentation/dsls/DSL-AshAge.DataLayer.md", "usage-rules.md"]
      ],
      groups_for_modules: [
        "Data Layer": [AshAge, AshAge.DataLayer, AshAge.DataLayer.Info, AshAge.Edge],
        Types: [
          AshAge.Type.Agtype,
          AshAge.Type.Vertex,
          AshAge.Type.Edge,
          AshAge.Type.Path,
          AshAge.Type.Cast,
          AshAge.Postgrex.AgtypeExtension
        ],
        Cypher: [AshAge.Cypher.Parameterized],
        Query: [AshAge.Query, AshAge.Query.Filter],
        Relationships: [
          AshAge.ManualRelationships.Traverse,
          AshAge.Changes.CreateEdge,
          AshAge.Changes.DestroyEdge
        ],
        "Multitenancy & RLS": [AshAge.Multitenancy],
        Verifiers: [
          AshAge.DataLayer.Verifiers.ValidateSensitive,
          AshAge.DataLayer.Verifiers.ValidateSkip,
          AshAge.DataLayer.Verifiers.ValidateMultitenancyAttr,
          AshAge.DataLayer.Verifiers.ValidateEdge
        ],
        Errors: [
          AshAge.Errors.CreateFailed,
          AshAge.Errors.QueryFailed,
          AshAge.Errors.UpdateFailed,
          AshAge.Errors.UnsupportedFilter
        ],
        Utilities: [AshAge.Graph, AshAge.Session, AshAge.Migration],
        "Mix Tasks": [
          Mix.Tasks.AshAge.Install,
          Mix.Tasks.AshAge.Gen.Migration,
          Mix.Tasks.AshAge.Verify
        ]
      ]
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "dialyzer"],
      "deps.audit": ["deps.unlock --check-unused", "hex.audit", "mix_audit"]
    ]
  end
end
