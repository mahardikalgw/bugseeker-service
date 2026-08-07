defmodule Codeseeker.Clients do
  @moduledoc """
  Resolves the HTTP client modules, allowing tests to swap in Mox mocks
  via `Application.put_env/3`.
  """

  @doc "GitHub REST client module (default: production Req implementation)."
  def github do
    Application.get_env(:codeseeker, :github_client, Codeseeker.Github.Client.Github)
  end

  @doc "LLM chat client module (default: production DeepSeek implementation)."
  def llm do
    Application.get_env(:codeseeker, :llm_client, Codeseeker.Llm.DeepSeek.OpenAI)
  end
end
