%{
  name: :mob_app_update,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description:
    "Self-update from GitHub Releases: check, download + sha256 verify, user-confirmed install (Android)",
  # On-device proof for `mix mob.selftest` / mob_ci: an installed/0 round trip
  # through the NIF and PackageManager (see Mob.Plugin.SelfTest).
  selftest: MobAppUpdate.SelfTest,
  nifs: [
    # Android only: zig NIF bridging to the Kotlin MobAppUpdateBridge
    # (PackageManager / PackageInstaller). iOS apps update through the App
    # Store / TestFlight, so there is no iOS NIF; MobAppUpdate answers
    # {:error, :unsupported} there.
    %{
      module: :mob_app_update_nif,
      native_dir: "priv/native/jni",
      lang: :zig,
      platform: :android
    }
  ],
  android: %{
    # Implements MobActivityAware — it needs a Context for PackageManager,
    # PackageInstaller and the confirmation / settings activities.
    bridge_kt: "priv/native/android/MobAppUpdateBridge.kt",
    bridge_class: "io.mob.appupdate.MobAppUpdateBridge",
    # PackageInstaller sessions need it; the user still grants "Install
    # unknown apps" per app (MobAppUpdate.open_install_settings/0) and
    # confirms every install.
    permissions: ["android.permission.REQUEST_INSTALL_PACKAGES"]
  }
}
