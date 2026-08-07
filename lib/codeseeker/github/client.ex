defmodule Codeseeker.Github.Client do
  @moduledoc """
  Behaviour for the GitHub REST client used by the review pipeline.

  `repo` is a plain map: `%{owner: String.t(), name: String.t(), installation_id: pos_integer()}`.
  """

  alias Codeseeker.Github.Error

  @type repo :: %{owner: String.t(), name: String.t(), installation_id: pos_integer()}
  @type pr_file :: %{
          path: String.t(),
          patch: String.t() | nil,
          additions: pos_integer(),
          deletions: pos_integer(),
          status: String.t(),
          sha: String.t()
        }
  @type review_comment :: %{
          path: String.t(),
          line: pos_integer(),
          side: String.t(),
          body: String.t()
        }

  @callback list_pr_files(repo(), pos_integer()) :: {:ok, [pr_file()]} | {:error, Error.t()}
  @callback post_review(repo(), pos_integer(), String.t(), String.t(), [review_comment()]) ::
              {:ok, map()} | {:error, Error.t()}
  @callback get_raw_contents(repo(), String.t(), String.t()) ::
              {:ok, binary()} | {:error, Error.t() | :not_found}
  @callback post_issue_comment(repo(), pos_integer(), String.t()) ::
              {:ok, map()} | {:error, Error.t()}
end
