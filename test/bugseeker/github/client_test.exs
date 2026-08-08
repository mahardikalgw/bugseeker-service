defmodule Bugseeker.Github.ClientTest do
  use ExUnit.Case, async: true

  alias Bugseeker.Github.{Client.Github, Error}

  setup do
    bypass = Bypass.open()
    installation_id = :erlang.unique_integer([:positive])
    Application.put_env(:bugseeker, :github_api_url, "http://localhost:#{bypass.port}")
    token_tid = :ets.new(:token_calls, [:public])

    on_exit(fn -> Application.delete_env(:bugseeker, :github_api_url) end)

    %{bypass: bypass, installation_id: installation_id, token_tid: token_tid}
  end

  defp repo(installation_id),
    do: %{owner: "acme-internal", name: "web-frontend", installation_id: installation_id}

  defp token_request?(conn), do: conn.method == "POST" and conn.request_path =~ "/access_tokens"

  defp token_response(conn, installation_id, token_tid) do
    :ets.update_counter(token_tid, :n, 1, {:n, 0})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      201,
      Jason.encode!(%{
        "token" => "install-token-#{installation_id}",
        "expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      })
    )
  end

  describe "list_pr_files/2" do
    test "fetches and maps files, paginating", %{
      bypass: bypass,
      installation_id: id,
      token_tid: tid
    } do
      Bypass.expect(bypass, fn conn ->
        cond do
          token_request?(conn) ->
            token_response(conn, id, tid)

          conn.request_path == "/repos/acme-internal/web-frontend/pulls/12/files" and
              conn.query_string == "per_page=100&page=1" ->
            Plug.Conn.put_resp_content_type(conn, "application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!([
                %{
                  "filename" => "a.ts",
                  "patch" => "@@ -1 +1 @@",
                  "additions" => 1,
                  "deletions" => 0,
                  "status" => "modified",
                  "sha" => "f1"
                },
                %{
                  "filename" => "b.go",
                  "patch" => "@@ -1 +1 @@",
                  "additions" => 1,
                  "deletions" => 0,
                  "status" => "modified",
                  "sha" => "f2"
                }
              ])
            )

          conn.request_path == "/repos/acme-internal/web-frontend/pulls/12/files" and
              conn.query_string == "per_page=100&page=2" ->
            Plug.Conn.put_resp_content_type(conn, "application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!([]))

          true ->
            Plug.Conn.send_resp(conn, 404, "unexpected: #{conn.request_path}")
        end
      end)

      assert {:ok, files} = Github.list_pr_files(repo(id), 12)
      assert length(files) == 2
      assert %{path: "a.ts", patch: "@@ -1 +1 @@", additions: 1} = hd(files)
    end

    test "caches the installation token across calls", %{
      bypass: bypass,
      installation_id: id,
      token_tid: tid
    } do
      Bypass.expect(bypass, fn conn ->
        if token_request?(conn) do
          token_response(conn, id, tid)
        else
          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!([]))
        end
      end)

      assert {:ok, _} = Github.list_pr_files(repo(id), 12)
      assert {:ok, _} = Github.list_pr_files(repo(id), 13)
      assert :ets.lookup_element(tid, :n, 2) == 1
    end

    test "refreshes the token once on 401 and retries", %{
      bypass: bypass,
      installation_id: id,
      token_tid: tid
    } do
      calls_tid = :ets.new(:file_calls, [:public])

      Bypass.expect(bypass, fn conn ->
        cond do
          token_request?(conn) ->
            token_response(conn, id, tid)

          conn.request_path =~ "/pulls/" ->
            case :ets.update_counter(calls_tid, :n, 1, {:n, 0}) do
              1 ->
                Plug.Conn.put_resp_content_type(conn, "application/json")
                |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "Bad credentials"}))

              _ ->
                Plug.Conn.put_resp_content_type(conn, "application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!([]))
            end

          true ->
            Plug.Conn.put_resp_content_type(conn, "application/json")
            |> Plug.Conn.send_resp(404, "unexpected")
        end
      end)

      assert {:ok, []} = Github.list_pr_files(repo(id), 12)
      assert :ets.lookup_element(calls_tid, :n, 2) == 2
    end
  end

  describe "post_review/5" do
    test "posts the review payload", %{bypass: bypass, installation_id: id, token_tid: tid} do
      Bypass.expect(bypass, fn conn ->
        if token_request?(conn) do
          token_response(conn, id, tid)
        else
          {:ok, body, _} = Plug.Conn.read_body(conn)
          payload = Jason.decode!(body)

          assert payload["event"] == "COMMENT"
          assert payload["commit_id"] == "sha1"
          assert [%{"path" => "a.ts", "line" => 3, "side" => "RIGHT"}] = payload["comments"]

          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => 7}))
        end
      end)

      assert {:ok, %{"id" => 7}} =
               Github.post_review(repo(id), 12, "sha1", "summary", [
                 %{path: "a.ts", line: 3, side: "RIGHT", body: "issue"}
               ])
    end

    test "maps a 422 to invalid_line", %{bypass: bypass, installation_id: id, token_tid: tid} do
      Bypass.expect(bypass, fn conn ->
        if token_request?(conn) do
          token_response(conn, id, tid)
        else
          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(
            422,
            Jason.encode!(%{"message" => "Comments can only be placed on lines within the diff"})
          )
        end
      end)

      assert {:error, %Error{reason: :invalid_line, status: 422}} =
               Github.post_review(repo(id), 12, "sha1", "summary", [])
    end
  end

  describe "get_raw_contents/3" do
    test "returns raw content", %{bypass: bypass, installation_id: id, token_tid: tid} do
      Bypass.expect(bypass, fn conn ->
        if token_request?(conn) do
          token_response(conn, id, tid)
        else
          assert conn.request_path =~ "/contents/docs/engineering-guidelines.md"
          Plug.Conn.send_resp(conn, 200, "guideline text")
        end
      end)

      assert {:ok, "guideline text"} =
               Github.get_raw_contents(repo(id), "docs/engineering-guidelines.md", "main")
    end

    test "maps 404 to :not_found", %{bypass: bypass, installation_id: id, token_tid: tid} do
      Bypass.expect(bypass, fn conn ->
        if token_request?(conn) do
          token_response(conn, id, tid)
        else
          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(404, Jason.encode!(%{"message" => "Not Found"}))
        end
      end)

      assert {:error, :not_found} =
               Github.get_raw_contents(repo(id), "docs/engineering-guidelines.md", "main")
    end
  end

  describe "post_issue_comment/3" do
    test "posts a comment", %{bypass: bypass, installation_id: id, token_tid: tid} do
      Bypass.expect(bypass, fn conn ->
        if token_request?(conn) do
          token_response(conn, id, tid)
        else
          {:ok, body, _} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["body"] == "hello"

          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"id" => 1}))
        end
      end)

      assert {:ok, %{"id" => 1}} = Github.post_issue_comment(repo(id), 12, "hello")
    end
  end
end
