defmodule Mix.Tasks.MobAppUpdate.PublishTest do
  # Not async: sets env vars and the Mix shell.
  use ExUnit.Case, async: false

  alias Mix.Tasks.MobAppUpdate.Publish

  @moduletag :tmp_dir

  @cert String.duplicate("3c", 32)

  setup %{tmp_dir: dir} do
    apk = Path.join(dir, "app-release.apk")
    File.write!(apk, "not really an apk, but bytes to hash")

    aapt2 =
      stub(dir, "aapt2", """
      echo "package: name='com.example.app' versionCode='42' versionName='1.4.0' platformBuildVersionName='15'"
      echo "sdkVersion:'28'"
      """)

    apksigner =
      stub(dir, "apksigner", """
      echo "Signer #1 certificate DN: CN=Android Debug, O=Android, C=US"
      echo "Signer #1 certificate SHA-256 digest: #{String.upcase(@cert)}"
      echo "Signer #1 certificate SHA-1 digest: 0000000000000000000000000000000000000000"
      """)

    System.put_env("MOB_APP_UPDATE_AAPT2", aapt2)
    System.put_env("MOB_APP_UPDATE_APKSIGNER", apksigner)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      System.delete_env("MOB_APP_UPDATE_AAPT2")
      System.delete_env("MOB_APP_UPDATE_APKSIGNER")
      Mix.shell(Mix.Shell.IO)
    end)

    %{apk: apk, out: Path.join(dir, "out")}
  end

  defp stub(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp infos(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> infos([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "--dry-run writes update.json + .sha256 and prints the gh command", %{apk: apk, out: out} do
    sha = :crypto.hash(:sha256, File.read!(apk)) |> Base.encode16(case: :lower)

    Publish.run(
      ~w(--repo o/app --apk #{apk} --tag v1.4.0 --target 0abc123 --prerelease --dry-run --out #{out})
    )

    assert JSON.decode!(File.read!(Path.join(out, "update.json"))) == %{
             "package" => "com.example.app",
             "version_code" => 42,
             "version_name" => "1.4.0",
             "apk" => "app-release.apk",
             "sha256" => sha,
             "size" => File.stat!(apk).size
           }

    assert File.read!(Path.join(out, "app-release.apk.sha256")) == "#{sha}  app-release.apk\n"

    lines = infos()
    assert "Signer certificate SHA-256: #{@cert}" in lines

    assert ("Dry run; would run: gh release create v1.4.0 #{apk} #{out}/update.json " <>
              "#{out}/app-release.apk.sha256 --repo o/app --title v1.4.0 --notes \"\" --target 0abc123 --prerelease") in lines
  end

  test "a failing apksigner stops before anything is written", %{apk: apk, out: out, tmp_dir: dir} do
    System.put_env(
      "MOB_APP_UPDATE_APKSIGNER",
      stub(dir, "bad_apksigner", "echo 'DOES NOT VERIFY'; exit 1")
    )

    assert_raise Mix.Error, ~r/apksigner verify failed \(exit 1\):\nDOES NOT VERIFY/, fn ->
      Publish.run(~w(--repo o/app --apk #{apk} --tag v1 --dry-run --out #{out}))
    end

    refute File.exists?(out)
  end

  test "an APK name GitHub would rewrite is refused", %{tmp_dir: dir, out: out} do
    apk = Path.join(dir, "my app.apk")
    File.write!(apk, "x")

    assert_raise Mix.Error, ~r/GitHub would rename it/, fn ->
      Publish.run(["--repo", "o/app", "--apk", apk, "--tag", "v1", "--dry-run", "--out", out])
    end
  end

  test "required options are enforced", %{apk: apk} do
    assert_raise Mix.Error, "--tag is required", fn ->
      Publish.run(~w(--repo o/app --apk #{apk}))
    end
  end
end
