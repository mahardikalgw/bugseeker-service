defmodule Codeseeker.Github.AppAuth do
  @moduledoc """
  Signs a short-lived RS256 JWT with the GitHub App private key and
  exchanges it for installation access tokens (TTL 1 hour), cached per
  installation until they are about to expire.

  Mirrors the flow described in the PRD (§9): GitHub App + JWT, not a PAT.
  """

  use GenServer

  alias Codeseeker.Github.Error

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns a valid installation access token for `installation_id`.

  Uses the cached token when it still has more than 30s of lifetime.
  """
  @spec token(pos_integer()) :: {:ok, String.t()} | {:error, Error.t()}
  def token(installation_id), do: GenServer.call(__MODULE__, {:token, installation_id})

  @doc """
  Forces a token refresh (used after a 401).
  """
  @spec refresh(pos_integer()) :: {:ok, String.t()} | {:error, Error.t()}
  def refresh(installation_id), do: GenServer.call(__MODULE__, {:refresh, installation_id})

  @impl true
  def init(_opts) do
    path = get_in(Application.get_env(:codeseeker, :github), [:private_key_path])

    pem =
      case path && File.read(path) do
        {:ok, pem} -> pem
        _ -> raise "GITHUB_APP_PRIVATE_KEY_PATH is missing or unreadable at #{inspect(path)}"
      end

    app_id = get_in(Application.get_env(:codeseeker, :github), [:app_id])

    signer = Joken.Signer.create("RS256", %{"pem" => pem})

    {:ok, %{app_id: app_id, signer: signer, tokens: %{}}}
  end

  @impl true
  def handle_call({:token, installation_id}, _from, state) do
    case Map.fetch(state.tokens, installation_id) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:reply, {:ok, token}, state}
        else
          do_fetch(installation_id, state)
        end

      _ ->
        do_fetch(installation_id, state)
    end
  end

  def handle_call({:refresh, installation_id}, _from, state) do
    do_fetch(installation_id, state)
  end

  defp do_fetch(installation_id, state) do
    case fetch_installation_token(installation_id, state) do
      {:ok, %{"token" => token, "expires_at" => expires_at}} ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, expiry, _offset} ->
            tokens = Map.put(state.tokens, installation_id, %{token: token, expires_at: expiry})
            {:reply, {:ok, token}, %{state | tokens: tokens}}

          _ ->
            {:reply,
             {:error,
              %Error{
                reason: :api_error,
                retryable?: true,
                message: "invalid expires_at in response"
              }}, state}
        end

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp fetch_installation_token(installation_id, state) do
    jwt = sign_jwt(state)
    api_url = Application.get_env(:codeseeker, :github_api_url, "https://api.github.com")

    case Req.post(
           "#{api_url}/app/installations/#{installation_id}/access_tokens",
           headers: [accept: "application/vnd.github+json", authorization: "Bearer #{jwt}"]
         ) do
      {:ok, %{status: 201, body: body}} ->
        decode_token_body(body)

      {:ok, %{status: status, body: body}} ->
        {:error, error_from(status, body)}

      {:error, reason} ->
        {:error, %Error{reason: :api_error, retryable?: true, message: inspect(reason)}}
    end
  end

  defp decode_token_body(body) when is_map(body), do: {:ok, body}

  defp decode_token_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        {:error,
         %Error{reason: :api_error, retryable?: true, message: "invalid token response body"}}
    end
  end

  defp decode_token_body(_body) do
    {:error, %Error{reason: :api_error, retryable?: true, message: "invalid token response body"}}
  end

  defp sign_jwt(%{app_id: app_id, signer: signer}) do
    now = System.system_time(:second)

    claims = %{"iss" => app_id, "iat" => now, "exp" => now + 540}

    case Joken.encode_and_sign(claims, signer) do
      {:ok, jwt, _claims} -> jwt
      {:error, reason} -> raise "could not sign JWT: #{inspect(reason)}"
    end
  end

  defp error_from(status, body) do
    %Error{
      status: status,
      body: body,
      reason: :api_error,
      retryable?: status in [401, 403, 500, 502, 503, 504],
      message: "GitHub API responded #{status}"
    }
  end
end
