defmodule MobAppUpdate.InstallTest do
  use ExUnit.Case, async: true

  alias MobAppUpdate.Install

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    File.mkdir_p!(downloads)
    %{downloads: downloads}
  end

  defp staged(downloads), do: Path.wildcard(Path.join(downloads, "install-*.apk"))

  test "an APK directly in the private download dir is used in place", %{downloads: downloads} do
    apk = Path.join(downloads, "app.apk")
    File.write!(apk, "apk bytes")

    assert Install.stage(apk, downloads, 1000) == {:ok, apk, 9, false}
    assert staged(downloads) == []
  end

  test "an APK anywhere else is copied into the download dir; the original stays", %{
    tmp_dir: tmp,
    downloads: downloads
  } do
    shared = Path.join([tmp, "shared", "app.apk"])
    File.mkdir_p!(Path.dirname(shared))
    File.write!(shared, "apk bytes")

    assert {:ok, copy, 9, true} = Install.stage(shared, downloads, 1000)
    assert [^copy] = staged(downloads)
    assert File.read!(copy) == "apk bytes"

    # Later changes to the shared file don't reach the checked copy.
    File.write!(shared, "swapped")
    assert File.read!(copy) == "apk bytes"
  end

  test "a symlink in the download dir is not trusted in place", %{
    tmp_dir: tmp,
    downloads: downloads
  } do
    target = Path.join(tmp, "elsewhere.apk")
    File.write!(target, "apk bytes")
    link = Path.join(downloads, "app.apk")
    File.ln_s!(target, link)

    assert {:ok, copy, 9, true} = Install.stage(link, downloads, 1000)
    assert copy != link
    assert File.read!(copy) == "apk bytes"
  end

  test "the size cap applies in place and to copies", %{tmp_dir: tmp, downloads: downloads} do
    apk = Path.join(downloads, "app.apk")
    File.write!(apk, "apk bytes")
    assert Install.stage(apk, downloads, 8) == {:error, {:apk_too_large, 9, 8}}

    shared = Path.join(tmp, "big.apk")
    File.write!(shared, "apk bytes")
    assert Install.stage(shared, downloads, 8) == {:error, {:apk_too_large, 9, 8}}
    assert staged(downloads) == []
  end

  test "a missing file or a directory is reported", %{tmp_dir: tmp, downloads: downloads} do
    missing = Path.join(tmp, "missing.apk")
    assert Install.stage(missing, downloads, 1000) == {:error, {:no_such_file, missing}}
    assert Install.stage(tmp, downloads, 1000) == {:error, {:no_such_file, tmp}}
  end
end
