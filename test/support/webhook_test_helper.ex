defmodule BugseekerWeb.WebhookTestHelper do
  @moduledoc """
  Builds signed webhook requests for controller tests, mimicking GitHub's
  `X-Hub-Signature-256` HMAC-SHA256 scheme.
  """

  import Plug.Conn, only: [put_req_header: 3]

  @secret "test_webhook_secret"

  @doc "HMAC-SHA256 hex signature for `body`, as GitHub would send it."
  def sign(secret \\ @secret, body) do
    "sha256=" <>
      Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  @doc "Builds a POST /webhook/github conn with a valid signature, run through the endpoint."
  def signed_conn(event, payload) do
    body = Jason.encode!(payload)

    conn =
      Plug.Test.conn(:post, "/webhook/github", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", event)
      |> put_req_header("x-hub-signature-256", sign(@secret, body))

    BugseekerWeb.Endpoint.call(conn, [])
  end

  @doc "A pull_request `opened` payload with a repo + installation."
  def pull_request_payload(opts \\ %{}) do
    opts = Map.new(opts)

    %{
      "action" => Map.get(opts, :action, "opened"),
      "number" => Map.get(opts, :number, 12),
      "repository" => %{
        "id" => 100,
        "name" => "web-frontend",
        "owner" => %{"login" => "acme-internal"}
      },
      "installation" => %{"id" => 42},
      "pull_request" => %{
        "head" => %{
          "sha" => Map.get(opts, :head_sha, "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c")
        },
        "base" => %{"sha" => "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"}
      }
    }
  end

  @doc "An issue_comment `created` payload."
  def issue_comment_payload(body, opts \\ %{}) do
    %{
      "action" => "created",
      "issue" => %{"number" => Map.get(opts, :number, 12)},
      "comment" => %{"body" => body, "user" => %{"login" => "dev-user"}},
      "repository" => %{
        "id" => 100,
        "name" => "web-frontend",
        "owner" => %{"login" => "acme-internal"}
      },
      "installation" => %{"id" => 42}
    }
  end
end
