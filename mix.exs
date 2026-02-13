defmodule AshAge.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_age,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      package: package()
    ]
  end

  defp deps do
    [
      # Ash dependency - will be provided by parent projects
      # that depend on ash_age via Hex. Version matches Ash 3.16
      {:ash, "~> 3.11"},
      {:splode, "~> 0.3"},
      {:spark, ">= 2.3.3 and < 3.0.0-0"},
      {:jason, "~> 1.2"},
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"}
    ]
  end

  defp package do
    [
      files: ["lib", "test", "mix.exs", "README*", "LICENSE*", "CONTRIBUTING*", "usage-rules.md", "AGENTS.md"],
      licenses: ["MIT"],
      links: %{
        "GitHub": "https://github.com/baselabs/ash_age",
        "Documentation": "https://hexdocs.pm/ash_age"
      }
    ]
  end
end
