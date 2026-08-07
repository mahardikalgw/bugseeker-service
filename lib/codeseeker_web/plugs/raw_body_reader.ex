defmodule CodeseekerWeb.Plugs.RawBodyReader do
  @moduledoc """
  Stores the raw request body in `conn.assigns[:raw_body]` before the
  normal parser reads it, so the webhook controller can verify the
  `X-Hub-Signature-256` HMAC against the exact bytes GitHub sent.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], fn existing -> existing || body end)
    {:ok, body, conn}
  end
end
