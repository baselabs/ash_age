import Config

# The string-length counting basis this package's resources are compiled against (Ash >= 3.33
# refuses to compile a :string constraint until it is explicit). Host applications set the same
# line in their own config; the library never mutates global Ash config at runtime.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  import_config "test.exs"
end
