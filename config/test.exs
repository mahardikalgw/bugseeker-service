import Config

config :codeseeker, CodeseekerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "RmuY0tzepJyZx2Eck6t1oCMk8zUYNmYMXAP5mN6cwWjMHVG3WlXBQkXUSjgwqJ1p",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

# Dummy GitHub App credentials for tests (never used for real API calls —
# all HTTP is mocked via Mox). The PEM fixture is a throwaway RSA key.
config :codeseeker, :github, %{
  app_id: "12345",
  private_key_path: Path.expand("fixtures/test_app_key.pem", __DIR__ <> "/../test/support"),
  webhook_secret: "test_webhook_secret"
}

# Test doubles for the HTTP clients
config :codeseeker, :github_client, Codeseeker.Github.Client.Mock
config :codeseeker, :llm_client, Codeseeker.Llm.DeepSeek.Mock
