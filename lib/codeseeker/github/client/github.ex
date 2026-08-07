defmodule Codeseeker.Github.Client.Github do
  @moduledoc """
  Req-based implementation of `Codeseeker.Github.Client`.

  Uses a GitHub App installation token obtained from
  `Codeseeker.Github.AppAuth` and refreshes it once on a 401.
  """

  @behaviour Codeseeker.Github.Client

  alias Codeseeker.Github.{AppAuth, Error}

  @api_url "https://api.github.com"
  @accept "application/vnd.github+json"

  @impl true
  def list_pr_files(repo, pr_number) do
    with {:ok, files} <- fetch_all_files(repo, pr_number, 1, []) do
      {:ok, files}
    end
  end

  @impl true
  def post_review(repo, pr_number, head_sha, body, comments) do
    payload = %{
      "commit_id" => head_sha,
      "event" => "COMMENT",
      "body" => body,
      "comments" =>
        Enum.map(comments, fn %{path: path, line: line, side: side, body: body} ->
          %{"path" => path, "line" => line, "side" => side, "body" => body}
        end)
    }

    case api_call(:post, repo, "/repos/#{full_name(repo)}/pulls/#{pr_number}/reviews", payload) do
      {:ok, response} -> {:ok, response.body}
      {:error, %Error{status: 422} = error} -> {:error, %{error | reason: :invalid_line}}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def get_raw_contents(repo, path, ref) do
    encoded = URI.encode(path, fn char -> URI.char_unreserved?(char) or char == ?/ end)

    case api_call(:get, repo, "/repos/#{full_name(repo)}/contents/#{encoded}?ref=#{ref}", nil,
           raw: true
         ) do
      {:ok, response} -> {:ok, response.body}
      {:error, %Error{status: 404}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def post_issue_comment(repo, pr_number, body) do
    case api_call(:post, repo, "/repos/#{full_name(repo)}/issues/#{pr_number}/comments", %{
           "body" => body
         }) do
      {:ok, response} -> {:ok, response.body}
      {:error, error} -> {:error, error}
    end
  end

  ## Private

  defp fetch_all_files(_repo, _pr_number, page, _acc) when page > 30, do: {:ok, []}

  defp fetch_all_files(repo, pr_number, page, acc) do
    path = "/repos/#{full_name(repo)}/pulls/#{pr_number}/files?per_page=100&page=#{page}"

    with {:ok, response} <- api_call(:get, repo, path) do
      files =
        response.body
        |> Enum.map(fn file ->
          %{
            path: file["filename"],
            patch: file["patch"],
            additions: file["additions"] || 0,
            deletions: file["deletions"] || 0,
            status: file["status"],
            sha: file["sha"]
          }
        end)

      if length(files) < 100 do
        {:ok, acc ++ files}
      else
        fetch_all_files(repo, pr_number, page + 1, acc ++ files)
      end
    end
  end

  defp api_call(method, repo, path, payload \\ nil, opts \\ []) do
    case do_api_call(method, repo, path, payload, opts) do
      {:error, %Error{status: 401} = error} ->
        # Token expired mid-flight: force a refresh and retry once.
        with {:ok, _} <- AppAuth.refresh(repo.installation_id) do
          do_api_call(method, repo, path, payload, opts)
        else
          _ -> {:error, error}
        end

      result ->
        result
    end
  end

  defp do_api_call(method, repo, path, payload, opts) do
    with {:ok, token} <- AppAuth.token(repo.installation_id) do
      request = build_request(method, path, payload, token, opts)

      case Req.request(request) do
        {:ok, response} when response.status in 200..299 ->
          {:ok, response}

        {:ok, %{status: status, body: body}} ->
          {:error, error_from(status, body)}

        {:error, reason} ->
          {:error,
           %Error{
             reason: :api_error,
             retryable?: true,
             message: "transport error: #{inspect(reason)}"
           }}
      end
    end
  end

  defp build_request(method, path, payload, token, opts) do
    api_url = Application.get_env(:codeseeker, :github_api_url, @api_url)

    base = [
      method: method,
      url: api_url <> path,
      headers: [
        accept: if(opts[:raw], do: "application/vnd.github.raw", else: @accept),
        authorization: "Bearer #{token}"
      ],
      receive_timeout: 30_000
    ]

    if method == :post && payload, do: Keyword.put(base, :json, payload), else: base
  end

  defp full_name(repo), do: "#{repo.owner}/#{repo.name}"

  defp error_from(status, body) do
    %Error{
      status: status,
      body: body,
      reason: :api_error,
      retryable?: status in [401, 403, 429, 500, 502, 503, 504],
      message: "GitHub API responded #{status}: #{inspect(body) |> String.slice(0, 300)}"
    }
  end
end
