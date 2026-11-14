defmodule MobAppUpdate.Release do
  @moduledoc """
  GitHub release JSON + the release's update metadata → the release map
  `MobAppUpdate.check/1` returns. Pure: no network, no NIF.

  ## The metadata asset

  Every release an app should offer carries a small JSON asset (default name
  `update.json`, written by `mix mob_app_update.publish`):

      {"package": "com.example.app", "version_code": 42, "version_name": "1.4.0",
       "apk": "app-release.apk", "sha256": "<64 hex>", "size": 104857600}

  `apk` names an asset of the same release whose size must equal `size`; when
  GitHub reports the asset's `digest` (`"sha256:<hex>"`) it must equal
  `sha256`. The installed app's `versionCode` is compared with `version_code`.

  ## The size cap

  Whoever can edit a release controls both `size` and the asset, so their
  agreement is no limit. `size` must also be at most `:max_size` (default
  #{300 * 1024 * 1024} bytes, 300 MiB), which `MobAppUpdate.download/2` enforces
  again on the streamed bytes.
  """

  @default_max_size 300 * 1024 * 1024

  @typedoc "The APK to download."
  @type apk :: %{
          name: String.t(),
          url: String.t(),
          size: pos_integer(),
          sha256: String.t()
        }

  @typedoc "An update candidate, as `MobAppUpdate.check/1` returns it."
  @type t :: %{
          tag: String.t(),
          name: String.t() | nil,
          notes: String.t(),
          published_at: DateTime.t() | nil,
          html_url: String.t() | nil,
          prerelease: boolean(),
          version_code: pos_integer(),
          version_name: String.t(),
          package: String.t(),
          apk: apk()
        }

  @typedoc "The installed app (`MobAppUpdate.installed/0`)."
  @type installed :: %{
          package: String.t(),
          version_code: pos_integer(),
          version_name: String.t()
        }

  @doc """
  The APK size cap from `opts[:max_size]` (a positive integer of bytes),
  default 300 MiB.
  """
  @spec max_size(keyword()) :: pos_integer()
  def max_size(opts) do
    case Keyword.get(opts, :max_size, @default_max_size) do
      max when is_integer(max) and max > 0 -> max
      other -> raise ArgumentError, ":max_size must be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc """
  Whether `release` (one entry of the GitHub releases API) has the shape the
  rest of this module reads: a map with a string `tag_name`, string-or-null
  `name` / `body` / `html_url`, and a list of asset maps with string names.
  """
  @spec well_formed?(term()) :: boolean()
  def well_formed?(%{"tag_name" => tag, "assets" => assets} = release)
      when is_binary(tag) and is_list(assets) do
    Enum.all?(["name", "body", "html_url"], &optional_string?(release[&1])) and
      Enum.all?(assets, &match?(%{"name" => name} when is_binary(name), &1))
  end

  def well_formed?(_), do: false

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  @doc """
  The newest release to consider from a `GET /repos/:repo/releases` page
  (newest first, each `well_formed?/1`): the first one that is not a draft
  and carries the metadata asset `metadata_asset`, or `nil`.
  """
  @spec pick([map()], String.t()) :: map() | nil
  def pick(releases, metadata_asset) when is_list(releases) do
    Enum.find(releases, &(&1["draft"] != true and asset(&1, metadata_asset) != nil))
  end

  @doc "The asset of `release` named `name`, or `nil`."
  @spec asset(map(), String.t()) :: map() | nil
  def asset(%{"assets" => assets}, name) when is_list(assets) do
    Enum.find(assets, &match?(%{"name" => ^name}, &1))
  end

  def asset(_release, _name), do: nil

  @doc """
  Validates `metadata` (the decoded metadata asset) against `release`'s assets
  and builds the release map. `opts`: `:max_size` (see the moduledoc).

  Errors: `{:invalid_metadata, field}` for a missing or malformed field,
  `{:apk_too_large, size, max_size}`,
  `{:metadata_mismatch, {:missing_asset, name}}`,
  `{:metadata_mismatch, {:size, metadata_size, asset_size}}`,
  `{:metadata_mismatch, {:sha256, metadata_sha256, github_digest}}`.
  """
  @spec build(map(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(release, metadata, opts \\ []) do
    with {:ok, meta} <- parse_metadata(metadata),
         :ok <- check_cap(meta.size, max_size(opts)),
         {:ok, apk_asset} <- apk_asset(release, meta.apk),
         :ok <- check_size(meta, apk_asset),
         :ok <- check_digest(meta, apk_asset) do
      {:ok,
       %{
         tag: release["tag_name"],
         name: release["name"],
         notes: release["body"] || "",
         published_at: parse_time(release["published_at"]),
         html_url: release["html_url"],
         prerelease: release["prerelease"] == true,
         version_code: meta.version_code,
         version_name: meta.version_name,
         package: meta.package,
         apk: %{
           name: meta.apk,
           url: apk_asset["browser_download_url"],
           size: meta.size,
           sha256: meta.sha256
         }
       }}
    end
  end

  @doc false
  # `{:error, {:apk_too_large, size, max}}` when `size` is over the cap.
  @spec check_cap(pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def check_cap(size, max) when size > max, do: {:error, {:apk_too_large, size, max}}
  def check_cap(_size, _max), do: :ok

  @doc """
  Compares `release` with the installed app: `{:ok, :available, release}` when
  its `version_code` is higher, `{:ok, :up_to_date, %{installed:, latest:}}`
  otherwise, `{:error, {:package_mismatch, installed_package,
  release_package}}` when the release is for another package.
  """
  @spec compare(t(), installed()) ::
          {:ok, :available, t()}
          | {:ok, :up_to_date, %{installed: installed(), latest: t()}}
          | {:error, {:package_mismatch, String.t(), String.t()}}
  def compare(%{package: package}, %{package: installed_package})
      when package != installed_package,
      do: {:error, {:package_mismatch, installed_package, package}}

  def compare(%{version_code: code} = release, %{version_code: installed_code})
      when code > installed_code,
      do: {:ok, :available, release}

  def compare(release, installed),
    do: {:ok, :up_to_date, %{installed: installed, latest: release}}

  defp parse_metadata(%{} = meta) do
    with {:ok, package} <- field(meta, :package, &non_empty_string?/1),
         {:ok, version_code} <- field(meta, :version_code, &pos_integer?/1),
         {:ok, version_name} <- field(meta, :version_name, &is_binary/1),
         {:ok, apk} <- field(meta, :apk, &asset_name?/1),
         {:ok, sha256} <- field(meta, :sha256, &sha256?/1),
         {:ok, size} <- field(meta, :size, &pos_integer?/1) do
      {:ok,
       %{
         package: package,
         version_code: version_code,
         version_name: version_name,
         apk: apk,
         sha256: String.downcase(sha256),
         size: size
       }}
    end
  end

  defp parse_metadata(_), do: {:error, {:invalid_metadata, :not_an_object}}

  defp field(meta, key, valid?) do
    value = meta[Atom.to_string(key)]
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_metadata, key}}
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""
  defp pos_integer?(value), do: is_integer(value) and value > 0

  # A bare file name: it becomes the download's file name.
  defp asset_name?(value),
    do: non_empty_string?(value) and Path.basename(value) == value and value not in [".", ".."]

  defp sha256?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-fA-F]{64}\z/

  defp apk_asset(release, name) do
    case asset(release, name) do
      %{"browser_download_url" => url} = asset when is_binary(url) -> {:ok, asset}
      _ -> {:error, {:metadata_mismatch, {:missing_asset, name}}}
    end
  end

  defp check_size(%{size: size}, %{"size" => size}), do: :ok

  defp check_size(%{size: size}, asset),
    do: {:error, {:metadata_mismatch, {:size, size, asset["size"]}}}

  defp check_digest(%{sha256: sha256}, %{"digest" => "sha256:" <> digest}) do
    if String.downcase(digest) == sha256,
      do: :ok,
      else: {:error, {:metadata_mismatch, {:sha256, sha256, String.downcase(digest)}}}
  end

  # No digest (older assets), or another algorithm: the download's own
  # sha256 check still applies.
  defp check_digest(_meta, _asset), do: :ok

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      {:error, _} -> nil
    end
  end

  defp parse_time(_), do: nil
end
