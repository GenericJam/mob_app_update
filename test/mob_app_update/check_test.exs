defmodule MobAppUpdate.CheckTest do
  use ExUnit.Case, async: true

  alias MobAppUpdate.TestServer

  @sha String.duplicate("0f", 32)
  @installed %{package: "com.example.app", version_code: 5, version_name: "1.5.0"}

  setup do
    server = TestServer.start()
    %{server: server, opts: [repo: "o/app", api_base: server.url, installed: @installed]}
  end

  # A release whose assets live on the test server; `meta` is served as its
  # update.json (nil: no metadata asset).
  defp release(server, tag, meta, opts \\ []) do
    meta_asset =
      if meta do
        TestServer.route(server, "/dl/#{tag}/update.json", {200, [], JSON.encode!(meta)})

        [
          %{
            "name" => "update.json",
            "size" => 100,
            "browser_download_url" => "#{server.url}/dl/#{tag}/update.json"
          }
        ]
      else
        []
      end

    %{
      "tag_name" => tag,
      "name" => tag,
      "body" => "",
      "published_at" => nil,
      "html_url" => nil,
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false),
      "assets" =>
        meta_asset ++
          [
            %{
              "name" => "app.apk",
              "size" => 2048,
              "browser_download_url" => "#{server.url}/dl/#{tag}/app.apk",
              "digest" => Keyword.get(opts, :digest, "sha256:" <> @sha)
            }
          ]
    }
  end

  defp meta(version_code, overrides \\ %{}) do
    Map.merge(
      %{
        "package" => "com.example.app",
        "version_code" => version_code,
        "version_name" => "1.#{version_code}.0",
        "apk" => "app.apk",
        "sha256" => @sha,
        "size" => 2048
      },
      overrides
    )
  end

  defp serve_latest(server, release),
    do: TestServer.route(server, "/repos/o/app/releases/latest", {200, [], JSON.encode!(release)})

  defp serve_list(server, releases),
    do:
      TestServer.route(
        server,
        "/repos/o/app/releases?per_page=30",
        {200, [], JSON.encode!(releases)}
      )

  test "latest mode: a higher version_code is available", %{server: server, opts: opts} do
    serve_latest(server, release(server, "v1.6.0", meta(6)))

    assert {:ok, :available, %{tag: "v1.6.0", version_code: 6, apk: %{url: url}}} =
             MobAppUpdate.check(opts)

    assert url == "#{server.url}/dl/v1.6.0/app.apk"

    assert_received {:test_server, "/repos/o/app/releases/latest",
                     %{"user-agent" => "mob_app_update"}}
  end

  test "latest mode: the same version_code is up to date", %{server: server, opts: opts} do
    serve_latest(server, release(server, "v1.5.0", meta(5)))

    assert {:ok, :up_to_date, %{installed: @installed, latest: %{tag: "v1.5.0"}}} =
             MobAppUpdate.check(opts)
  end

  test "latest mode: a latest release without metadata is an error, no release at all another",
       %{server: server, opts: opts} do
    assert MobAppUpdate.check(opts) == {:error, :no_release}

    serve_latest(server, release(server, "v1.6.0", nil))
    assert MobAppUpdate.check(opts) == {:error, :no_update_metadata}
  end

  test "prerelease mode takes the newest non-draft release with metadata", %{
    server: server,
    opts: opts
  } do
    serve_list(server, [
      release(server, "v1.9.0", meta(9), draft: true),
      release(server, "v1.8.0-rc1", nil, prerelease: true),
      release(server, "v1.7.0-rc1", meta(7), prerelease: true),
      release(server, "v1.6.0", meta(6))
    ])

    assert {:ok, :available, %{tag: "v1.7.0-rc1", prerelease: true}} =
             MobAppUpdate.check([prerelease: true] ++ opts)
  end

  test "prerelease mode with no usable release is up to date with latest: nil", %{
    server: server,
    opts: opts
  } do
    serve_list(server, [release(server, "v1.6.0", nil)])

    assert MobAppUpdate.check([prerelease: true] ++ opts) ==
             {:ok, :up_to_date, %{installed: @installed, latest: nil}}
  end

  test "a GitHub digest that disagrees with update.json is refused", %{server: server, opts: opts} do
    bad = String.duplicate("aa", 32)
    serve_latest(server, release(server, "v1.6.0", meta(6), digest: "sha256:" <> bad))

    assert MobAppUpdate.check(opts) == {:error, {:metadata_mismatch, {:sha256, @sha, bad}}}
  end

  test "metadata for another package is refused", %{server: server, opts: opts} do
    serve_latest(server, release(server, "v1.6.0", meta(6, %{"package" => "com.evil"})))

    assert MobAppUpdate.check(opts) ==
             {:error, {:package_mismatch, "com.example.app", "com.evil"}}
  end

  test "metadata that isn't JSON is reported", %{server: server, opts: opts} do
    serve_latest(server, release(server, "v1.6.0", meta(6)))
    TestServer.route(server, "/dl/v1.6.0/update.json", {200, [], "<html>"})

    assert MobAppUpdate.check(opts) == {:error, {:invalid_metadata, :not_json}}
  end

  test "the metadata download follows GitHub's redirect to the asset host", %{
    server: server,
    opts: opts
  } do
    rel = release(server, "v1.6.0", meta(6))
    TestServer.redirect(server, "/redirect/update.json", "/dl/v1.6.0/update.json")

    rel =
      put_in(
        rel,
        ["assets", Access.at(0), "browser_download_url"],
        "#{server.url}/redirect/update.json"
      )

    serve_latest(server, rel)

    assert {:ok, :available, %{version_code: 6}} = MobAppUpdate.check(opts)
  end

  test "an exhausted rate limit is reported with its reset time", %{server: server, opts: opts} do
    TestServer.route(
      server,
      "/repos/o/app/releases/latest",
      {403, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1794830400"}], "{}"}
    )

    assert MobAppUpdate.check(opts) ==
             {:error, {:rate_limited, DateTime.from_unix!(1_794_830_400)}}
  end

  test "an invalid repo is refused before any request" do
    assert MobAppUpdate.check(repo: "not a repo", installed: @installed) ==
             {:error, {:invalid_repo, "not a repo"}}

    refute_received {:test_server, _, _}
  end

  test "off Android, without :installed, check is unsupported", %{opts: opts} do
    assert MobAppUpdate.check(Keyword.delete(opts, :installed)) == {:error, :unsupported}
  end
end
