defmodule MobAppUpdate.DownloadTest do
  use ExUnit.Case, async: true

  alias MobAppUpdate.TestServer

  @moduletag :tmp_dir

  # ~1.2 MB so progress is reported several times along the way.
  @apk :crypto.strong_rand_bytes(1_200_000)

  setup %{tmp_dir: dir} do
    server = TestServer.start()
    TestServer.route(server, "/assets/app.apk", {200, [], @apk})
    TestServer.redirect(server, "/o/app/releases/download/v2/app.apk", "/assets/app.apk")
    %{server: server, dir: dir}
  end

  defp release(server, overrides \\ %{}) do
    %{
      tag: "v2",
      version_code: 2,
      apk:
        Map.merge(
          %{
            name: "app.apk",
            url: "#{server.url}/o/app/releases/download/v2/app.apk",
            size: byte_size(@apk),
            sha256: :crypto.hash(:sha256, @apk) |> Base.encode16(case: :lower)
          },
          overrides
        )
    }
  end

  test "follows the redirect, streams to dir, reports progress", %{server: server, dir: dir} do
    me = self()
    total = byte_size(@apk)

    assert {:ok, path} =
             MobAppUpdate.download(release(server),
               dir: dir,
               notify: me,
               progress: fn bytes, total -> send(me, {:callback, bytes, total}) end
             )

    assert path == Path.join(dir, "app.apk")
    assert File.read!(path) == @apk
    assert File.ls!(dir) == ["app.apk"]

    assert_received {:mob_app_update, {:progress, 0, ^total}}
    assert_received {:mob_app_update, {:progress, ^total, ^total}}
    assert_received {:callback, ^total, ^total}

    # 0, then at least one intermediate report before the final one.
    assert [0, _, _ | _] = reported = collect_progress([])
    assert reported == Enum.sort(reported)
  end

  test "a sha256 mismatch deletes the file", %{server: server, dir: dir} do
    wrong = String.duplicate("00", 32)
    got = :crypto.hash(:sha256, @apk) |> Base.encode16(case: :lower)

    assert MobAppUpdate.download(release(server, %{sha256: wrong}), dir: dir) ==
             {:error, {:sha256_mismatch, wrong, got}}

    assert File.ls!(dir) == []
  end

  test "a body larger than the metadata size is cut off and deleted", %{server: server, dir: dir} do
    assert {:error, {:size_mismatch, 1000, got}} =
             MobAppUpdate.download(release(server, %{size: 1000}), dir: dir)

    assert got > 1000
    assert File.ls!(dir) == []
  end

  test "a short body is a size mismatch", %{server: server, dir: dir} do
    size = byte_size(@apk) + 1

    assert MobAppUpdate.download(release(server, %{size: size}), dir: dir) ==
             {:error, {:size_mismatch, size, byte_size(@apk)}}

    assert File.ls!(dir) == []
  end

  test "an HTTP error leaves nothing behind", %{server: server, dir: dir} do
    assert MobAppUpdate.download(release(server, %{url: "#{server.url}/missing.apk"}), dir: dir) ==
             {:error, :not_found}

    assert File.ls!(dir) == []
  end

  defp collect_progress(acc) do
    receive do
      {:callback, bytes, _} -> collect_progress([bytes | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
