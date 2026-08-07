defmodule CodeseekerWeb.WebhookController do
  @moduledoc """
  Receives GitHub webhooks, verifies the HMAC-SHA256 signature, filters
  events, and hands the work to `Codeseeker.CoordinatorSup` (or the
  `/codeseeker` command handler) so the response can be sent immediately.

  Never log full payloads — only repo/pr/event metadata.
  """

  use CodeseekerWeb, :controller

  require Logger

  alias Codeseeker.{Commands, CoordinatorSup}

  @github_event_header "x-github-event"
  @signature_header "x-hub-signature-256"
  @pull_request_actions ~w(opened synchronize)

  def github(conn, _params) do
    raw = conn.assigns[:raw_body] || ""

    with :ok <- verify_signature(conn, raw),
         :ok <- verify_event(conn),
         {:ok, payload} <- decode_payload(raw) do
      dispatch(conn, payload)
    else
      {:error, :bad_signature} ->
        Logger.warning("webhook signature verification failed", remote_ip: conn.remote_ip)
        put_status(conn, 401) |> json(%{error: "invalid signature"})

      {:error, :ignored} ->
        # Event we do not care about (ping, labeled, closed, ...): ack and move on.
        json(conn, %{ok: true})

      {:error, :bad_payload} ->
        put_status(conn, 400) |> json(%{error: "malformed payload"})
    end
  end

  ## Verification

  defp verify_signature(conn, raw) do
    secret = get_in(Application.get_env(:codeseeker, :github), [:webhook_secret])

    case get_req_header(conn, @signature_header) do
      [sig] ->
        expected =
          "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw), case: :lower)

        if Plug.Crypto.secure_compare(sig, expected) do
          :ok
        else
          {:error, :bad_signature}
        end

      [] ->
        {:error, :bad_signature}
    end
  end

  defp verify_event(conn) do
    case get_req_header(conn, @github_event_header) do
      [event] when event in ["pull_request", "issue_comment"] -> :ok
      _ -> {:error, :ignored}
    end
  end

  defp decode_payload(raw) do
    case Jason.decode(raw) do
      {:ok, payload} -> {:ok, payload}
      {:error, _} -> {:error, :bad_payload}
    end
  end

  ## Dispatch

  defp dispatch(conn, payload) do
    event = get_req_header(conn, @github_event_header) |> List.first()

    case event do
      "pull_request" -> dispatch_pull_request(conn, payload)
      "issue_comment" -> dispatch_issue_comment(conn, payload)
    end
  end

  defp dispatch_pull_request(conn, payload) do
    action = payload["action"]

    with true <- action in @pull_request_actions,
         %{owner: _owner, name: _name, installation_id: _id} = repo <- extract_repo(payload),
         %{"head" => %{"sha" => head_sha}, "base" => %{"sha" => base_sha}} <-
           payload["pull_request"],
         pr_number when is_integer(pr_number) <- payload["number"] do
      pr = %{
        repo: repo,
        pr_number: pr_number,
        head_sha: head_sha,
        base_sha: base_sha
      }

      Logger.info("webhook pull_request",
        action: action,
        repo: "#{repo.owner}/#{repo.name}",
        pr: pr.pr_number,
        head_sha: pr.head_sha
      )

      case CoordinatorSup.start_child(pr) do
        {:ok, _pid} ->
          json(conn, %{ok: true, dispatched: "coordinator"})

        {:error, reason} ->
          json(conn, %{ok: true, dispatched: "ignored", reason: inspect(reason)})
      end
    else
      _ -> json(conn, %{ok: true})
    end
  end

  defp dispatch_issue_comment(conn, payload) do
    with %{"action" => "created"} <- payload,
         %{owner: _owner, name: _name, installation_id: _id} = repo <- extract_repo(payload),
         %{"comment" => %{"body" => body, "user" => %{"login" => user}}} <- payload,
         %{"number" => pr_number} when is_integer(pr_number) <- payload["issue"],
         true <- is_binary(body) and String.starts_with?(body, "/codeseeker") do
      Logger.info("webhook command",
        repo: "#{repo.owner}/#{repo.name}",
        pr: pr_number,
        user: user
      )

      ctx = %{repo: repo, pr_number: pr_number, comment: body, user: user}

      # Commands reply via the GitHub API; run them off the request path.
      Task.start(fn -> Commands.run(ctx) end)
      json(conn, %{ok: true, dispatched: "command"})
    else
      _ -> json(conn, %{ok: true})
    end
  end

  defp extract_repo(payload) do
    with %{
           "repository" => %{
             "name" => name,
             "owner" => %{"login" => owner},
             "id" => github_repo_id
           }
         } <- payload,
         %{"installation" => %{"id" => installation_id}} <- payload do
      %{
        owner: owner,
        name: name,
        github_repo_id: github_repo_id,
        installation_id: installation_id
      }
    else
      _ -> nil
    end
  end
end
