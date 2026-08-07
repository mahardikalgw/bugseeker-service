defmodule Codeseeker.Llm.DeepSeek.OpenAI do
  @moduledoc """
  DeepSeek chat completions client backed by Req, using the OpenAI-compatible
  `/chat/completions` endpoint with JSON mode.
  """

  @behaviour Codeseeker.Llm.DeepSeek

  require Logger

  @impl true
  def chat(prompt) do
    api = Application.get_env(:codeseeker, :llm_api, %{})
    llm = Application.get_env(:codeseeker, :llm, %{})

    body = %{
      "model" => api[:model] || "deepseek-chat",
      "messages" => [%{"role" => "system", "content" => prompt}],
      "temperature" => llm[:temperature] || 0.1,
      "max_tokens" => llm[:max_tokens] || 4096,
      "response_format" => %{"type" => "json_object"}
    }

    url = (api[:api_url] || "https://api.deepseek.com") <> "/chat/completions"
    started = System.monotonic_time(:millisecond)

    result =
      Req.post(url,
        json: body,
        headers: [authorization: "Bearer #{api[:api_key]}"],
        receive_timeout: llm[:timeout_ms] || 120_000,
        connect_options: [timeout: llm[:connect_timeout_ms] || 10_000]
      )

    duration = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        Logger.info("deepseek",
          status: status,
          duration_ms: duration,
          prompt_chars: byte_size(prompt)
        )

        content = get_in(response_body, ["choices", Access.at(0), "message", "content"])
        {:ok, %{content: content, raw: response_body}}

      {:ok, %{status: 429, body: body}} ->
        Logger.warning("deepseek rate limited", duration_ms: duration)
        {:error, %{type: :rate_limited, message: inspect(body) |> String.slice(0, 300)}}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        Logger.warning("deepseek api error", status: status, duration_ms: duration)
        {:error, %{type: :api_error, message: inspect(body) |> String.slice(0, 300)}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("deepseek unexpected status", status: status)
        {:error, %{type: :api_error, message: inspect(body) |> String.slice(0, 300)}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("deepseek timeout", duration_ms: duration)
        {:error, %{type: :timeout, message: "timeout after #{duration}ms"}}

      {:error, reason} ->
        Logger.warning("deepseek transport error", error: inspect(reason))
        {:error, %{type: :api_error, message: inspect(reason)}}
    end
  end
end
