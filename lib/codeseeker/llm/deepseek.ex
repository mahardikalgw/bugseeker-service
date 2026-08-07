defmodule Codeseeker.Llm.DeepSeek do
  @moduledoc """
  Behaviour for the LLM chat client used to review file diffs.
  """

  @type chat_result ::
          {:ok, %{content: String.t(), raw: map()}}
          | {:error, %{type: :timeout | :rate_limited | :api_error, message: String.t()}}

  @callback chat(String.t()) :: chat_result()
end
