import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

# In dev, secrets may come from a local .env file — load it before reading
# any environment variables below. Tests define all config in config/test.exs
# and must not be affected by a developer's local .env.
if config_env() == :dev do
  Dotenv.load!()
end

if System.get_env("PHX_SERVER") do
  config :codeseeker, CodeseekerWeb.Endpoint, server: true
end

config :codeseeker, CodeseekerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# GitHub App credentials. Required in prod; in dev/test, values may come
# from .env or from compile-time config (tests define their own).
strict? = config_env() == :prod
existing_github = Application.get_env(:codeseeker, :github) || %{}

github = %{
  app_id: System.get_env("GITHUB_APP_ID") || existing_github[:app_id],
  private_key_path:
    System.get_env("GITHUB_APP_PRIVATE_KEY_PATH") || existing_github[:private_key_path],
  webhook_secret: System.get_env("GITHUB_WEBHOOK_SECRET") || existing_github[:webhook_secret]
}

if strict? do
  Enum.each(github, fn {key, value} ->
    if is_nil(value) do
      env_name =
        case key do
          :app_id -> "GITHUB_APP_ID"
          :private_key_path -> "GITHUB_APP_PRIVATE_KEY_PATH"
          :webhook_secret -> "GITHUB_WEBHOOK_SECRET"
        end

      raise "environment variable #{env_name} is missing"
    end
  end)
end

config :codeseeker, :github, github

config :codeseeker, :llm_api, %{
  api_key: System.get_env("DEEPSEEK_API_KEY"),
  api_url: System.get_env("DEEPSEEK_API_URL") || "https://api.deepseek.com",
  model: System.get_env("DEEPSEEK_MODEL") || "deepseek-chat"
}
