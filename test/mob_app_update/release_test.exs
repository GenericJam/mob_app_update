defmodule MobAppUpdate.ReleaseTest do
  use ExUnit.Case, async: true

  alias MobAppUpdate.Release

  @sha String.duplicate("ab", 32)

  defp gh_release(tag, opts \\ []) do
    assets =
      Keyword.get(opts, :assets, [
        %{
          "name" => "update.json",
          "size" => 120,
          "browser_download_url" => "https://x/#{tag}/update.json"
        },
        %{
          "name" => "app.apk",
          "size" => 1000,
          "browser_download_url" => "https://x/#{tag}/app.apk",
          "digest" => Keyword.get(opts, :digest, "sha256:" <> @sha)
        }
      ])

    %{
      "tag_name" => tag,
      "name" => "Release #{tag}",
      "body" => "notes for #{tag}",
      "published_at" => "2026-11-13T10:00:00Z",
      "html_url" => "https://github.com/o/r/releases/tag/#{tag}",
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false),
      "assets" => assets
    }
  end

  defp metadata(overrides \\ %{}) do
    Map.merge(
      %{
        "package" => "com.example.app",
        "version_code" => 7,
        "version_name" => "1.7.0",
        "apk" => "app.apk",
        "sha256" => @sha,
        "size" => 1000
      },
      overrides
    )
  end

  describe "pick/2" do
    test "skips drafts and releases without the metadata asset, newest first" do
      releases = [
        gh_release("v4", draft: true),
        gh_release("v3", assets: [%{"name" => "app.apk", "size" => 1}]),
        gh_release("v2", prerelease: true),
        gh_release("v1")
      ]

      assert %{"tag_name" => "v2"} = Release.pick(releases, "update.json")
    end

    test "nil when no release carries the metadata asset" do
      assert Release.pick([gh_release("v1")], "other.json") == nil
    end
  end

  describe "build/3" do
    test "builds the release map from the release and its metadata" do
      assert {:ok, release} =
               Release.build(gh_release("v1.7.0"), metadata(%{"sha256" => String.upcase(@sha)}))

      assert release == %{
               tag: "v1.7.0",
               name: "Release v1.7.0",
               notes: "notes for v1.7.0",
               published_at: ~U[2026-11-13 10:00:00Z],
               html_url: "https://github.com/o/r/releases/tag/v1.7.0",
               prerelease: false,
               version_code: 7,
               version_name: "1.7.0",
               package: "com.example.app",
               apk: %{name: "app.apk", url: "https://x/v1.7.0/app.apk", size: 1000, sha256: @sha}
             }
    end

    test "a GitHub digest that disagrees with the metadata sha256 is a mismatch" do
      other = String.duplicate("cd", 32)

      assert Release.build(gh_release("v1", digest: "sha256:" <> other), metadata()) ==
               {:error, {:metadata_mismatch, {:sha256, @sha, other}}}
    end

    test "no digest (or another algorithm) leaves the check to the download" do
      assert {:ok, _} = Release.build(gh_release("v1", digest: nil), metadata())
      assert {:ok, _} = Release.build(gh_release("v1", digest: "sha512:00"), metadata())
    end

    test "the APK asset must exist and match the metadata size" do
      assert Release.build(gh_release("v1"), metadata(%{"apk" => "other.apk"})) ==
               {:error, {:metadata_mismatch, {:missing_asset, "other.apk"}}}

      assert Release.build(gh_release("v1"), metadata(%{"size" => 999})) ==
               {:error, {:metadata_mismatch, {:size, 999, 1000}}}
    end

    test "an APK over the size cap is refused even when GitHub agrees with the metadata" do
      big = 300 * 1024 * 1024 + 1
      [meta_asset, apk_asset] = gh_release("v1")["assets"]
      release = Map.put(gh_release("v1"), "assets", [meta_asset, %{apk_asset | "size" => big}])

      assert Release.build(release, metadata(%{"size" => big})) ==
               {:error, {:apk_too_large, big, 300 * 1024 * 1024}}

      assert Release.build(gh_release("v1"), metadata(), max_size: 999) ==
               {:error, {:apk_too_large, 1000, 999}}

      assert {:ok, _} = Release.build(gh_release("v1"), metadata(), max_size: 1000)
    end

    test "rejects malformed metadata field by field" do
      assert Release.build(gh_release("v1"), metadata(%{"version_code" => "7"})) ==
               {:error, {:invalid_metadata, :version_code}}

      assert Release.build(gh_release("v1"), metadata(%{"sha256" => "abc"})) ==
               {:error, {:invalid_metadata, :sha256}}

      assert Release.build(gh_release("v1"), metadata(%{"apk" => "../app.apk"})) ==
               {:error, {:invalid_metadata, :apk}}

      assert Release.build(gh_release("v1"), ["not", "a", "map"]) ==
               {:error, {:invalid_metadata, :not_an_object}}
    end
  end

  describe "compare/2" do
    setup do
      {:ok, release} = Release.build(gh_release("v1.7.0"), metadata())
      %{release: release}
    end

    test "available only for a higher version_code", %{release: release} do
      older = %{package: "com.example.app", version_code: 6, version_name: "1.6.0"}
      same = %{older | version_code: 7}

      assert Release.compare(release, older) == {:ok, :available, release}

      assert Release.compare(release, same) ==
               {:ok, :up_to_date, %{installed: same, latest: release}}
    end

    test "a release for another package is refused", %{release: release} do
      installed = %{package: "com.example.other", version_code: 1, version_name: "1"}

      assert Release.compare(release, installed) ==
               {:error, {:package_mismatch, "com.example.other", "com.example.app"}}
    end
  end
end
