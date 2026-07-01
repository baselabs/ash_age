defmodule AshAge.TestDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  # Integration-test resources are defined inline in their test modules and point
  # their `domain:` here; allow_unregistered? lets them run without being listed.
  resources do
    allow_unregistered? true
  end
end
