defmodule Codeseeker.Exclusions do
  @moduledoc """
  Decides which files of a PR diff are worth reviewing and which must be
  skipped (lockfiles, generated code, binaries, oversized patches) with a
  human-readable reason, per the PRD's noise-control goals.

  Pure module; configuration comes from `config :codeseeker, :exclusions`.
  """

  @type pr_file :: %{path: String.t(), patch: String.t() | nil, additions: integer()}

  @doc """
  Filters `files` into the ones to review and the skipped ones.

  Returns `{kept, skipped}` where `skipped` is a list of
  `%{path: path, reason: reason}` maps. Skips are ordered by the file
  order and a file is skipped by the first matching rule.
  """
  @spec filter([pr_file()]) :: {[pr_file()], [%{path: String.t(), reason: String.t()}]}
  def filter(files) do
    max_files = Application.get_env(:codeseeker, :max_files_per_pr, 30)
    config = Application.get_env(:codeseeker, :exclusions, %{})

    files
    |> Enum.take(max_files)
    |> Enum.map(&classify(&1, config))
    |> split_kept(max_files, length(files))
  end

  defp classify(file, config) do
    cond do
      excluded_pattern?(file.path, config) ->
        {:skip, %{path: file.path, reason: "excluded pattern"}}

      binary_patch?(file.patch, config) ->
        {:skip, %{path: file.path, reason: "binary file"}}

      oversized?(file, config) ->
        {:skip, %{path: file.path, reason: "diff too large — manual review recommended"}}

      is_nil(file.patch) ->
        {:skip, %{path: file.path, reason: "no patch"}}

      true ->
        {:keep, file}
    end
  end

  defp split_kept(classified, max_files, total) do
    {kept, skipped} =
      Enum.reduce(classified, {[], []}, fn
        {:keep, file}, {kept, skipped} -> {[file | kept], skipped}
        {:skip, skip}, {kept, skipped} -> {kept, [skip | skipped]}
      end)

    skipped =
      if total > max_files do
        skipped ++
          [%{path: "(#{total - max_files} more files)", reason: "#{max_files}-file limit per PR"}]
      else
        skipped
      end

    {Enum.reverse(kept), Enum.reverse(skipped)}
  end

  defp excluded_pattern?(path, config) do
    Enum.any?(config[:patterns] || [], &Regex.match?(&1, path))
  end

  defp binary_patch?(patch, config) do
    markers = config[:binary_markers] || ["Binary files differ", <<0>>]
    patch != nil and Enum.any?(markers, &String.contains?(patch, &1))
  end

  defp oversized?(%{patch: patch, additions: additions}, config) do
    patch != nil and
      (byte_size(patch) > (config[:max_patch_bytes] || 300_000) or
         additions > (config[:max_added_lines] || 1_500))
  end
end
