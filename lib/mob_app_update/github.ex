defmodule MobAppUpdate.GitHub do
  @moduledoc false
  # The two GitHub reads behind MobAppUpdate.check/1: the candidate release
  # (REST API) and its metadata asset (a download, which doesn't count against
  # the API rate limit). Unauthenticated: 60 API requests per hour per IP.

  alias MobAppUpdate.{HTTP, Release}

  @api_headers [
    {"accept", "application/vnd.github+json"},
    {"x-github-api-version", "2022-11-28"}
  ]
  @max_api_body 4 * 1024 * 1024
  @max_metadata 64 * 1024
  @per_page 30

  @doc false
  # Latest mode: GET /repos/:repo/releases/latest (newest non-draft,
  # non-prerelease); it must carry the metadata asset. Prerelease mode: the
  # newest non-draft release on the first page of GET /repos/:repo/releases
  # that carries it, pre-releases included; nil when none does.
  @spec candidate(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def candidate(repo, opts) do
    asset = Keyword.get(opts, :metadata_asset, "update.json")

    if Keyword.get(opts, :prerelease, false) do
      with {:ok, releases} <- api(repo, "/releases?per_page=#{@per_page}", opts) do
        if is_list(releases),
          do: {:ok, Release.pick(releases, asset)},
          else: {:error, {:bad_response, :releases}}
      end
    else
      case api(repo, "/releases/latest", opts) do
        {:ok, %{} = release} ->
          if Release.asset(release, asset),
            do: {:ok, release},
            else: {:error, :no_update_metadata}

        {:ok, _} ->
          {:error, {:bad_response, :latest}}

        {:error, :not_found} ->
          {:error, :no_release}

        error ->
          error
      end
    end
  end

  @doc false
  @spec metadata(map(), keyword()) :: {:ok, term()} | {:error, term()}
  def metadata(release, opts) do
    asset = Release.asset(release, Keyword.get(opts, :metadata_asset, "update.json"))

    with {:ok, body} <- HTTP.get(asset["browser_download_url"], [], opts, @max_metadata) do
      case JSON.decode(body) do
        {:ok, meta} -> {:ok, meta}
        {:error, _} -> {:error, {:invalid_metadata, :not_json}}
      end
    end
  end

  defp api(repo, path, opts) do
    base = opts |> Keyword.get(:api_base, "https://api.github.com") |> String.trim_trailing("/")

    with {:ok, body} <-
           HTTP.get("#{base}/repos/#{repo}#{path}", @api_headers, opts, @max_api_body) do
      case JSON.decode(body) do
        {:ok, json} -> {:ok, json}
        {:error, _} -> {:error, {:bad_response, :not_json}}
      end
    end
  end
end
