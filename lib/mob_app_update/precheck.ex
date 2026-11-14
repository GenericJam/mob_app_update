defmodule MobAppUpdate.Precheck do
  @moduledoc """
  The pre-install check `MobAppUpdate.install/2` runs on a downloaded APK,
  before it opens a `PackageInstaller` session. Pure: it compares what
  `PackageManager` reports for the installed app and for the APK file
  (`getPackageArchiveInfo` with `GET_SIGNING_CERTIFICATES`).

  Android enforces the same rules when it installs; checking first turns a
  generic install failure into a clear error and, for the common cases, avoids
  showing the user a confirmation for an install that can't succeed.

  Signers are SHA-256 digests (lowercase hex) of the signing certificates;
  `signer_history` is `SigningInfo.getSigningCertificateHistory()` (oldest
  first, the current signer last; empty with multiple signers). The APK
  passes when it is for the same package, has a higher `versionCode`, and its
  signers are compatible the way Android's update check
  (`PackageManagerServiceUtils.verifySignatures`) defines it:

    * either side signed by several certificates: the two sets are equal
      (rotation isn't supported with multiple signers);
    * one signer each: the same certificate; or the installed signer is in
      the APK's rotation lineage (a rotated key, `INSTALLED_DATA` capability
      at install time); or the APK's signer is in the installed app's
      lineage (`ROLLBACK` capability).

  The public SDK reports a lineage's certificates but not their capability
  flags (`Signature.getFlags` is hidden), so a lineage relation passes here
  and Android makes the capability decision at install time; if a lineage
  revoked that capability, the install ends in `{:failure, status, message}`
  rather than in a pre-check error. Certificates with no relation at all are
  refused here, since Android certainly refuses them.
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

      not compatible_signers?(installed, apk) ->
        {:error, {:signature_mismatch, installed.signers, apk.signers}}

      true ->
        :ok
    end
  end

  defp compatible_signers?(%{signers: []}, _apk), do: false
  defp compatible_signers?(_installed, %{signers: []}), do: false

  # Rotation only exists for a single signer on both sides.
  defp compatible_signers?(
         %{signers: [old], multiple_signers: false} = installed,
         %{
           signers: [new],
           multiple_signers: false
         } = apk
       ) do
    old == new or old in apk.signer_history or new in installed.signer_history
  end

  defp compatible_signers?(installed, apk),
    do: MapSet.new(installed.signers) == MapSet.new(apk.signers)
end
