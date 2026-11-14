defmodule MobAppUpdate.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One read-only native round trip: `MobAppUpdate.installed/0` goes through
  the zig NIF into `MobAppUpdateBridge.info()` (PackageManager) and back as
  JSON. A positive `versionCode` for a non-empty package name is `:pass`.

  On iOS the plugin has no native side (updates go through TestFlight / the
  App Store), so the test is skipped.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(%{platform: :android}), do: classify(MobAppUpdate.installed())

  def run(%{platform: platform}),
    do: {:skip, "Android-only plugin; nothing to prove on #{platform}"}

  @doc false
  @spec classify(term()) :: :pass | {:fail, String.t()}
  def classify({:ok, %{package: package, version_code: code}})
      when is_binary(package) and package != "" and is_integer(code) and code > 0,
      do: :pass

  def classify(other), do: {:fail, "installed/0 returned #{inspect(other)}"}
end
