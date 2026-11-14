# 2026-11-13 — Self-update from GitHub Releases as a Mob plugin

## Context

FMutate is distributed as a sideloaded APK, and so will Humdinger and Magpie
be for testers. Each new build currently means a manual download and install.
We want the app to find a newer build of itself, fetch it, and offer to
install it, with the user's confirmation and without a server of our own.

## Decision

### A plugin, not app code and not mob core

`mob_app_update` is a small capability plugin (the size of `mob_background`):
an Elixir API, a zig NIF and one Kotlin bridge. The same flow serves FMutate,
Humdinger and Magpie, so it shouldn't be copied into each app; and mob core
shouldn't carry `REQUEST_INSTALL_PACKAGES` for every app, which is what an
activated plugin gives us: the permission is merged only into apps that opt
in through `config :mob, :plugins`.

The plugin is Android only. iOS apps update through TestFlight / the App
Store; on iOS (and on a host) every call answers `{:error, :unsupported}`.

### Releases live on GitHub Releases

No update server: the app reads the repository's releases from the public
REST API (unauthenticated, 60 requests per hour per IP, so the host app
rate-limits its checks) and downloads assets from GitHub's CDN.

* `check/1` reads `GET /repos/:repo/releases/latest` by default: GitHub's
  latest release is the newest non-draft, non-prerelease one, so stable
  users only see stable builds.
* `prerelease: true` reads `GET /repos/:repo/releases` and takes the newest
  non-draft release with update metadata, pre-releases included. That's the
  opt-in tester channel. Drafts are never offered.
* A release is an update only if it carries `update.json` (package,
  `version_code`, `version_name`, APK asset name, sha256, size), written by
  `mix mob_app_update.publish`. Releases without it are skipped (prerelease
  mode) or reported as `{:error, :no_update_metadata}` (latest mode). The
  comparison is on `versionCode`, the number Android itself compares, not on
  tags or version names.

### Trust model

* **Authenticity comes from Android's signature rule.** An APK can only
  replace an installed app if it is signed by the same certificate (or one
  the installed app's key rotation lineage vouches for). An attacker who
  could change a release still can't install code without the signing key.
  `mix mob_app_update.publish` never touches signing keys; it verifies the
  APK with `apksigner` and prints the signer certificate's SHA-256 so the
  publisher sees which key signed it.
* **We pre-check what Android would enforce**, so the user gets a clear
  error instead of a generic install failure: before opening the install
  session, `install/2` reads the APK with
  `PackageManager.getPackageArchiveInfo(GET_SIGNING_CERTIFICATES)` and
  requires the installed package name, a higher `versionCode`, and signers
  Android's update rule (`verifySignatures`) can accept: the same
  certificate set; or, single signers only, the installed signer in the
  APK's rotation lineage (`INSTALLED_DATA`) or the APK's signer in the
  installed lineage (`ROLLBACK`). The public SDK lists a lineage's
  certificates but not their capability flags (`Signature.getFlags` is
  hidden), so for a rotated key the pre-check only rules out certificates
  with no relation, and Android decides the capability at install time (a
  refusal is an install `{:failure, ...}`, after the confirmation). Parsing
  the v3 signing block ourselves to read the flags was rejected: a lot of
  code for a case (a lineage that revokes a capability) none of our apps
  has, with Android enforcing it regardless. `check/1` also refuses
  metadata naming another package.
* **The pre-check binds to the installed bytes.** Android parses the APK by
  path and the bridge reopens it later on its worker thread, so the file
  must be one nobody else can swap in between: an APK directly in the app's
  private download dir is used in place; any other path (or a symlink) is
  first copied there under a fresh name, and that copy is checked and
  installed.
* **sha256 guards the download's integrity, not its authenticity.** The
  metadata's sha256 and size are checked after streaming the APK to disk
  (the file is deleted on a mismatch), and when GitHub reports the asset's
  `digest` it must equal the metadata's sha256. That catches truncated or
  corrupted downloads and a metadata/asset mix-up; whoever can edit the
  release can edit both, which is why authenticity rests on the signature.
* **Disk use is capped by the app, not by the release.** The same editor
  controls the metadata's size and the asset, so the app sets `max_size`
  (default 300 MiB): larger metadata is refused before any download, and
  the stream is cut off at the metadata size. The download and the
  installer's session copy each require free space for the APK plus 64 MiB
  first; Android's own `allocateBytes` in `openWrite` still guards the
  session.
* **HTTPS only** with peer verification (`:ssl` `verify_peer` and hostname
  checks). The BEAM has no CA store on Android, so the plugin reads
  `/system/etc/security/cacerts`. Redirects (GitHub's asset links redirect
  to another host) are followed by the plugin, each hop with TLS options for
  its own host and each hop required to be `https://`; `http://` is
  accepted only to loopback hosts and only with `allow_loopback_http: true`
  (tests, `adb reverse`).

### UX

* **No silent installs.** The `PackageInstaller` session asks for user action
  on Android 12+ (`USER_ACTION_REQUIRED`), and every
  `STATUS_PENDING_USER_ACTION` opens the system confirmation; the app can't
  skip it.
* **First-time permission.** Android requires the user to allow "Install
  unknown apps" for this app once. `can_request_installs?/0` tells the app
  whether that's done; `open_install_settings/0` opens the switch for this
  app. The app explains why before sending the user there, then checks again
  on resume. `install/2` answers `{:error, :install_permission_required}`
  rather than starting a session that would stall.
* **Up to date** is an answer, not an error: `{:ok, :up_to_date, %{installed:,
  latest:}}`.
* **Errors** are specific tuples (`:rate_limited` with its reset time,
  `:metadata_mismatch`, `:sha256_mismatch`, `:not_an_update`,
  `:signature_mismatch`, ...) so the app can word them.
* **Progress.** The APK (~100 MB) streams to a file in the app's cache dir
  with flow control, reported to a callback and/or a process. Downloads left
  over by an earlier run (including the one an update installed, since
  Android stops the app to replace it) are deleted when the app next starts.

## What this doesn't cover

* **iOS.** TestFlight / the App Store.
* **Copies installed from Google Play.** Play owns their updates (and on
  Android 14+ may hold update ownership); an app distributed both ways should
  only call `check/1` in its sideloaded build.
* **Resumable downloads, delta updates, background or scheduled checks,
  private repositories.** The host decides when to check; a check costs one
  API request plus one metadata download.
