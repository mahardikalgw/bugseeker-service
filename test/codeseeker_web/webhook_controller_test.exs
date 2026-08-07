defmodule CodeseekerWeb.WebhookControllerTest do
  use CodeseekerWeb.ConnCase, async: false

  import Mox

  alias Codeseeker.Github.Client.Mock, as: GithubMock

  alias CodeseekerWeb.WebhookTestHelper

  setup do
    Mox.set_mox_global()
    Mox.verify_on_exit!()

    # Stop leaked coordinators so they cannot consume mocks of this test.
    Codeseeker.CoordinatorSup
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Codeseeker.CoordinatorSup, pid)

      _ ->
        :ok
    end)

    if :ets.whereis(:codeseeker_dedup), do: :ets.delete_all_objects(:codeseeker_dedup)
    :ok
  end

  describe "signature verification" do
    test "accepts a valid signature and dispatches a coordinator" do
      expect(GithubMock, :list_pr_files, fn _repo, _pr -> {:ok, []} end)

      conn =
        WebhookTestHelper.signed_conn("pull_request", WebhookTestHelper.pull_request_payload())

      assert %{"ok" => true, "dispatched" => "coordinator"} = json_response(conn, 200)
      wait_until_review_finished("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c")
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
    test "opened and synchronize actions dispatch" do
      for action <- ["opened", "synchronize"] do
        expect(GithubMock, :list_pr_files, fn _repo, _pr -> {:ok, []} end)

        payload =
          WebhookTestHelper.pull_request_payload(action: action, head_sha: "sha-#{action}")

        conn = WebhookTestHelper.signed_conn("pull_request", payload)

        assert %{"dispatched" => "coordinator"} = json_response(conn, 200)
        wait_until_review_finished(payload["pull_request"]["head"]["sha"])
      end
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

  defp wait_until_review_finished(head_sha) do
    key = {"acme-internal", "web-frontend", 12, head_sha}
    deadline = System.monotonic_time(:millisecond) + 2_000

    unless Codeseeker.Dedup.done?(key) do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        wait_until_review_finished(head_sha)
      end
    end
  end
end
