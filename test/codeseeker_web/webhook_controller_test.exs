defmodule CodeseekerWeb.WebhookControllerTest do
  use CodeseekerWeb.ConnCase, async: false

  import Mox

  alias Codeseeker.Github.Client.Mock, as: GithubMock

  alias CodeseekerWeb.WebhookTestHelper

  setup do
    Mox.set_mox_global()
    Mox.verify_on_exit!()
    Ecto.Adapters.SQL.Sandbox.checkout(Codeseeker.Repo)
    :ok
  end

  describe "signature verification" do
    test "accepts a valid signature and enqueues a FetchDiffJob" do
      conn =
        WebhookTestHelper.signed_conn("pull_request", WebhookTestHelper.pull_request_payload())

      assert %{"ok" => true, "dispatched" => "fetch_diff"} = json_response(conn, 200)
      assert length(enqueued(Codeseeker.Jobs.FetchDiffJob)) == 1
    end

    test "rejects a tampered body with 401" do
      body = Jason.encode!(WebhookTestHelper.pull_request_payload())

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "pull_request")
        |> put_req_header(
          "x-hub-signature-256",
          WebhookTestHelper.sign("test_webhook_secret", body <> "x")
        )
        |> post("/webhook/github", body)

      assert json_response(conn, 401) == %{"error" => "invalid signature"}
      assert enqueued(Codeseeker.Jobs.FetchDiffJob) == []
    end

    test "rejects a request without a signature header with 401" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "pull_request")
        |> post("/webhook/github", Jason.encode!(WebhookTestHelper.pull_request_payload()))

      assert json_response(conn, 401) == %{"error" => "invalid signature"}
    end
  end

  describe "event filtering" do
    test "opened and synchronize actions enqueue a FetchDiffJob" do
      for action <- ["opened", "synchronize"] do
        payload =
          WebhookTestHelper.pull_request_payload(action: action, head_sha: "sha-#{action}")

        conn = WebhookTestHelper.signed_conn("pull_request", payload)

        assert %{"dispatched" => "fetch_diff"} = json_response(conn, 200)
      end

      assert length(enqueued(Codeseeker.Jobs.FetchDiffJob)) == 2
    end

    test "other actions and events are no-ops" do
      for action <- ["closed", "labeled", "edited"] do
        conn =
          WebhookTestHelper.signed_conn(
            "pull_request",
            WebhookTestHelper.pull_request_payload(action: action)
          )

        assert %{"ok" => true} = json_response(conn, 200)
      end

      conn = WebhookTestHelper.signed_conn("ping", %{"zen" => "keep it simple"})
      assert %{"ok" => true} = json_response(conn, 200)

      assert enqueued(Codeseeker.Jobs.FetchDiffJob) == []
    end
  end

  describe "issue_comment commands" do
    test "/codeseeker status replies via the GitHub API" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:command_reply, body})
        {:ok, %{id: 1}}
      end)

      conn =
        WebhookTestHelper.signed_conn(
          "issue_comment",
          WebhookTestHelper.issue_comment_payload("/codeseeker status")
        )

      assert %{"dispatched" => "command"} = json_response(conn, 200)
      assert_receive {:command_reply, body}, 1_000
      assert body =~ "**Codeseeker status**"
      assert body =~ "Active skills"
    end

    test "non-command comments are ignored" do
      conn =
        WebhookTestHelper.signed_conn(
          "issue_comment",
          WebhookTestHelper.issue_comment_payload("just a normal comment")
        )

      assert %{"ok" => true} = json_response(conn, 200)
    end
  end

  describe "malformed payload" do
    test "invalid JSON body is rejected (ParseError from the JSON parser)" do
      body = "this is not json"

      assert_raise Plug.Parsers.ParseError, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "pull_request")
        |> put_req_header(
          "x-hub-signature-256",
          WebhookTestHelper.sign("test_webhook_secret", body)
        )
        |> post("/webhook/github", body)
      end
    end

    test "valid JSON without repository fields is a safe no-op" do
      payload = %{"action" => "opened"}
      conn = WebhookTestHelper.signed_conn("pull_request", payload)
      assert %{"ok" => true} = json_response(conn, 200)
    end
  end

  defp enqueued(worker) do
    Oban.Testing.all_enqueued(repo: Codeseeker.Repo, worker: worker)
  end
end
