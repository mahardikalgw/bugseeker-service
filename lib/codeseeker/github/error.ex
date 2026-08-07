defmodule Codeseeker.Github.Error do
  @moduledoc """
  Normalized error returned by GitHub API calls.

  Fields:
    * `status` — HTTP status code, or `nil` for transport errors
    * `reason` — `:invalid_line` for 422 line errors, `:not_found` for 404s,
      otherwise `:api_error`
    * `retryable?` — true for 401/403/5xx and transport errors
  """

  defexception [:status, :body, :reason, :retryable?, :message]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          body: term(),
          reason: atom(),
          retryable?: boolean(),
          message: String.t()
        }

  @impl true
  def message(%__MODULE__{message: message}), do: message || "GitHub API error"
end
