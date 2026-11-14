defmodule MobAppUpdateTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    test "passes the pre-publish validator (paths, NIF module, bridge, permission, min_sdk)" do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      assert %{errors: []} = Validator.validate_plugin(manifest, @plugin_dir)
      assert manifest.android.permissions == ["android.permission.REQUEST_INSTALL_PACKAGES"]
      assert manifest.android.min_sdk == 28
    end
  end

  describe "off Android" do
    test "the native calls answer :unsupported instead of raising" do
      assert MobAppUpdate.installed() == {:error, :unsupported}
      assert MobAppUpdate.can_request_installs?() == false
      assert MobAppUpdate.open_install_settings() == {:error, :unsupported}
      assert MobAppUpdate.install("/tmp/app.apk") == {:error, :unsupported}
    end
  end

  describe "SelfTest.classify/1" do
    test "passes on a real installed version, fails on anything else" do
      assert MobAppUpdate.SelfTest.classify({:ok, %{package: "com.example.app", version_code: 3}}) ==
               :pass

      assert MobAppUpdate.SelfTest.classify({:error, :not_ready}) ==
               {:fail, "installed/0 returned {:error, :not_ready}"}
    end
  end
end
