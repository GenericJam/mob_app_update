defmodule MobAppUpdate.Precheck do
  @moduledoc """
  The pre-install check `MobAppUpdate.install/2` runs on a downloaded APK,
  before it opens a `PackageInstaller` session. Pure: it compares what
  `PackageManager` reports for the installed app and for the APK file
  (`getPackageArchiveInfo` with `GET_SIGNING_CERTIFICATES`).

  Android enforces the same rules when it installs; checking first turns a
  generic install failure into a clear error and avoids showing the user a
  confirmation for an install that can't succeed.

  Signers are SHA-256 digests (lowercase hex) of the signing certificates.
  The APK passes when it is for the same package, has a higher `versionCode`,
  and is signed by the same certificate set as the installed app, or (key
  rotation, APK Signature Scheme v3) when the installed app's single signer
  appears in the APK's proven signing-certificate history.
  """

  @type info :: MobAppUpdate.Native.package_info()

  @spec verify(info(), info()) ::
          :ok
          | {:error,
             {:package_mismatch, String.t(), String.t()}
             | {:not_an_update, integer(), integer()}
             | {:signature_mismatch, [String.t()], [String.t()]}}
  def verify(installed, apk) do
    cond do
      apk.package != installed.package ->
        {:error, {:package_mismatch, installed.package, apk.package}}

      not is_integer(apk.version_code) or apk.version_code <= installed.version_code ->
        {:error, {:not_an_update, installed.version_code, apk.version_code}}

      not same_signer?(installed, apk) ->
        {:error, {:signature_mismatch, installed.signers, apk.signers}}

      true ->
        :ok
    end
  end

  defp same_signer?(%{signers: []}, _apk), do: false
  defp same_signer?(_installed, %{signers: []}), do: false

  defp same_signer?(installed, apk) do
    MapSet.new(installed.signers) == MapSet.new(apk.signers) or rotated?(installed, apk)
  end

  defp rotated?(%{multiple_signers: false, signers: [current]}, %{multiple_signers: false} = apk),
    do: current in apk.signer_history

  defp rotated?(_installed, _apk), do: false
end
