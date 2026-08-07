defmodule CodeseekerWeb.Router do
  use CodeseekerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/webhook", CodeseekerWeb do
    pipe_through :api
    post "/github", WebhookController, :github
  end

  scope "/", CodeseekerWeb do
    get "/healthz", HealthController, :index
  end
end
