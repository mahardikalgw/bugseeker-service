defmodule CodeseekerWeb.HealthController do
  @moduledoc "Simple liveness probe used by Docker/CI health checks."

  use CodeseekerWeb, :controller

  def index(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
