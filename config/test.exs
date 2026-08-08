import Config

config :bugseeker, BugseekerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "RmuY0tzepJyZx2Eck6t1oCMk8zUYNmYMXAP5mN6cwWjMHVG3WlXBQkXUSjgwqJ1p",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

# Test database
# Local dev Postgres trusts password-less connections as the OS user; the CI
# postgres service creates user "postgres" with a password. PGUSER/PGPASSWORD
# let CI inject them without editing config.
repo_config = [
  hostname: "localhost",
  database: "bugseeker_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
]

repo_config =
  case System.get_env("PGUSER") do
    nil -> repo_config
    user -> Keyword.put(repo_config, :username, user)
  end

repo_config = Keyword.put(repo_config, :password, System.get_env("PGPASSWORD"))
config :bugseeker, Bugseeker.Repo, repo_config

# Oban in manual mode: tests enqueue/perform jobs explicitly. Testing mode
# disables queues, plugins, and uses an isolated (DB-free) peer; an isolated
# notifier avoids opening a Postgres LISTEN connection into the sandbox.
config :oban, Oban, testing: :manual, notifier: Oban.Notifiers.Isolated

# Dummy GitHub App credentials for tests (never used for real API calls —
# all HTTP is mocked via Mox). The PEM fixture is a throwaway RSA key.
config :bugseeker, :github, %{
  app_id: "12345",
  private_key_path: Path.expand("fixtures/test_app_key.pem", __DIR__ <> "/../test/support"),
  webhook_secret: "test_webhook_secret"
}

# Test doubles for the HTTP clients
config :bugseeker, :github_client, Bugseeker.Github.Client.Mock
config :bugseeker, :llm_client, Bugseeker.Llm.DeepSeek.Mock
