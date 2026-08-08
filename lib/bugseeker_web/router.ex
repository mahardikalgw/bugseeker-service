defmodule BugseekerWeb.Router do
  use BugseekerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/webhook", BugseekerWeb do
    pipe_through :api
    post "/github", WebhookController, :github
  end

  scope "/", BugseekerWeb do
    get "/healthz", HealthController, :index
  end
end
