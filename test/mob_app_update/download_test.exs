defmodule MobAppUpdate.DownloadTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MobAppUpdate.{Download, TestServer}

  @moduletag :tmp_dir

  # ~1.2 MB so progress is reported several times along the way.
  @apk :crypto.strong_rand_bytes(1_200_000)

  setup %{tmp_dir: dir} do
    server = TestServer.start()
    TestServer.route(server, "/assets/app.apk", {200, [], @apk})
    TestServer.redirect(server, "/o/app/releases/download/v2/app.apk", "/assets/app.apk")
    %{server: server, dir: dir, opts: [dir: dir, allow_loopback_http: true]}
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

  test "follows the redirect, streams to dir, reports progress", %{
    server: server,
    dir: dir,
    opts: opts
  } do
    me = self()
    total = byte_size(@apk)

    assert {:ok, path} =
             MobAppUpdate.download(
               release(server),
               [
                 notify: me,
                 progress: fn bytes, total -> send(me, {:callback, bytes, total}) end
               ] ++ opts
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

  test "a sha256 mismatch deletes the file", %{server: server, dir: dir, opts: opts} do
    wrong = String.duplicate("00", 32)
    got = :crypto.hash(:sha256, @apk) |> Base.encode16(case: :lower)

    assert MobAppUpdate.download(release(server, %{sha256: wrong}), opts) ==
             {:error, {:sha256_mismatch, wrong, got}}

    assert File.ls!(dir) == []
  end

  test "a body larger than the metadata size is cut off and deleted", %{
    server: server,
    dir: dir,
    opts: opts
  } do
    assert {:error, {:size_mismatch, 1000, got}} =
             MobAppUpdate.download(release(server, %{size: 1000}), opts)

    assert got > 1000
    assert File.ls!(dir) == []
  end

  test "a short body is a size mismatch", %{server: server, dir: dir, opts: opts} do
    size = byte_size(@apk) + 1

    assert MobAppUpdate.download(release(server, %{size: size}), opts) ==
             {:error, {:size_mismatch, size, byte_size(@apk)}}

    assert File.ls!(dir) == []
  end

  test "a release over the size cap is refused before any request", %{
    server: server,
    dir: dir,
    opts: opts
  } do
    huge = 10 * 1024 * 1024 * 1024

    assert MobAppUpdate.download(release(server, %{size: huge}), opts) ==
             {:error, {:apk_too_large, huge, 300 * 1024 * 1024}}

    size = byte_size(@apk)

    assert MobAppUpdate.download(release(server), [max_size: size - 1] ++ opts) ==
             {:error, {:apk_too_large, size, size - 1}}

    refute_received {:test_server, _, _}
    assert File.ls!(dir) == []
  end

  test "an http URL is refused without the loopback opt-in", %{server: server, dir: dir} do
    rel = release(server)

    assert MobAppUpdate.download(rel, dir: dir) == {:error, {:insecure_url, rel.apk.url}}
    refute_received {:test_server, _, _}
  end

  test "an HTTP error leaves nothing behind", %{server: server, dir: dir, opts: opts} do
    assert MobAppUpdate.download(release(server, %{url: "#{server.url}/missing.apk"}), opts) ==
             {:error, :not_found}

    assert File.ls!(dir) == []
  end

  test "space/2 requires the APK plus a 64 MiB reserve" do
    reserve = 64 * 1024 * 1024
    assert Download.space(1000 + reserve, 1000) == :ok

    assert Download.space(999 + reserve, 1000) ==
             {:error, {:insufficient_space, 1000 + reserve, 999 + reserve}}
  end

  test "remove/1 logs a delete that fails", %{dir: dir} do
    # A non-empty directory can't be deleted with rm.
    blocked = Path.join(dir, "blocked")
    File.mkdir_p!(Path.join(blocked, "x"))

    assert capture_log(fn -> assert Download.remove(blocked) == :ok end) =~
             "could not delete #{blocked}"

    assert capture_log(fn -> Download.remove(Path.join(dir, "gone")) end) == ""
  end

  defp collect_progress(acc) do
    receive do
      {:callback, bytes, _} -> collect_progress([bytes | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
