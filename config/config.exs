# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# General application configuration
config :codeseeker,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :codeseeker, CodeseekerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: CodeseekerWeb.ErrorJSON],
    layout: false
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Files that are never reviewed, whatever their size.
# Patterns are strings (compiled at runtime) so releases can serialize them
# on every supported Elixir version.
config :codeseeker, :exclusions, %{
  patterns: [
    ~S(\.lock$),
    ~S(package-lock\.json$),
    ~S(yarn\.lock$),
    ~S(pnpm-lock\.yaml$),
    ~S(go\.sum$),
    ~S(mix\.lock$),
    ~S(\.min\.js$),
    ~S(\.min\.css$),
    ~S(\.pb\.go$),
    ~S(^dist/),
    ~S(^build/),
    ~S(^vendor/),
    ~S(node_modules/),
    ~S(\.svg$|\.png$|\.jpg$|\.jpeg$|\.ico$|\.gif$|\.webp$)
  ],
  max_patch_bytes: 300_000,
  max_added_lines: 1_500,
  binary_markers: ["Binary files differ", <<0>>]
}

# Extension -> skill name mapping. Path of each skill file is skills/<name>/README.md
config :codeseeker, :skills_manifest, %{
  ".ts" => "typescript",
  ".tsx" => "typescript",
  ".js" => "typescript",
  ".jsx" => "typescript",
  ".mjs" => "typescript",
  ".cjs" => "typescript",
  ".go" => "go",
  ".php" => "php",
  ".ex" => "elixir",
  ".exs" => "elixir"
}

config :codeseeker, :skills_dir, "skills"
config :codeseeker, :fallback_skill, "generic"

# DeepSeek LLM settings
config :codeseeker, :llm, %{
  temperature: 0.1,
  max_tokens: 4096,
  timeout_ms: 120_000,
  connect_timeout_ms: 10_000,
  max_retries: 3,
  retry_backoff_ms: [3_000, 9_000, 27_000]
}

# GitHub API retry backoff (per call, in ms)
config :codeseeker, :github_retry_backoff_ms, [2_000, 6_000, 18_000]

# Repository guidelines file fetched once per PR and appended to prompts
config :codeseeker, :guidelines_path, "docs/engineering-guidelines.md"

# Inline comments are posted for issues with severity >= this threshold.
# CRITICAL > HIGH > MEDIUM > LOW > INFO. Overridable per repo via PerRepo.
config :codeseeker, :min_inline_severity, "HIGH"

# Hard limits
config :codeseeker, :max_files_per_pr, 30
config :codeseeker, :dedup_ttl_seconds, 3600
config :codeseeker, :review_concurrency, 10

# Per-repo overrides (loaded at boot into Codeseeker.PerRepo).
# Omitting a repo means: bot enabled, all manifest skills active,
# min_inline_severity = global default.
config :codeseeker, :repos, %{}

# HTTP client modules (swapped for Mox mocks in tests)
config :codeseeker, :github_client, Codeseeker.Github.Client.Github
config :codeseeker, :llm_client, Codeseeker.Llm.DeepSeek.OpenAI

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
