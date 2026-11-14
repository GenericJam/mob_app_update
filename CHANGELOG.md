# Changelog

## [Unreleased]

### Security

- An absolute APK size cap, `max_size:` (default 300 MiB) on `check/1`,
  `download/2` and `install/2`: `{:error, {:apk_too_large, size,
  max_size}}`. The metadata's size is checked against it and the download
  is cut off at that size. `download/2` and `install/2` require free space
  for the APK plus 64 MiB on Android (`{:error, {:insufficient_space,
  needed, free}}`; new bridge call `freeSpace`, NIF
  `app_update_free_space/1`).
- HTTPS only, for every URL and every redirect hop:
  `{:error, {:insecure_url, url}}`. `allow_loopback_http: true` admits
  `http://` to loopback hosts only (tests, `adb reverse`).
- `install/2` checks and installs the same bytes: an APK outside the app's
  private download dir (or a symlink) is copied there first; the copy is
  pre-checked, installed and deleted, the original left alone.
- `mix mob_app_update.publish` refuses tags that aren't plain git tag
  names (path traversal, leading `-`), passes `gh` options as
  `--name=value` with the tag and files after `--`, and refuses paths with
  `#`.
- CI actions pinned to commit SHAs.

### Changed

- The signer pre-check follows Android's update rule: for single signers it
  also accepts an APK whose signer is in the installed app's rotation
  lineage (rollback), and leaves lineage capability flags (not in the SDK)
  to Android's install-time check. Unrelated certificates are still refused.
- Malformed GitHub responses (`"assets": {}`, non-string fields, a metadata
  asset without a URL) are `{:error, {:bad_response, :latest | :releases |
  :metadata_asset}}` instead of a crash; an out-of-range rate-limit reset is
  `{:rate_limited, nil}`.
- The manifest declares `android.min_sdk: 28`; below it the bridge answers
  `{:error, :unsupported}`.
- Failed deletes of partial downloads and installed APKs are logged.
- `download/2` reports a failed `mkdir` as `{:error, {:file, posix}}`.

## 0.1.0

### Added

- `MobAppUpdate`: `installed/0`, `check/1` (GitHub's latest release, or the
  newest pre-release with `prerelease: true`; `update.json` metadata
  validated against the release's assets and GitHub's asset digest),
  `download/2` (streamed to the cache dir with progress, size + sha256
  verified, redirects followed), `can_request_installs?/0`,
  `open_install_settings/0` and `install/2` (package / versionCode / signer
  pre-check via `getPackageArchiveInfo`, then a user-confirmed
  `PackageInstaller` session; status messages to the caller).
- `mix mob_app_update.publish`: reads the APK with `aapt2`, verifies it with
  `apksigner`, writes `update.json` + `<apk>.sha256` and runs
  `gh release create` (`--dry-run` prints the command).
- Android zig NIF + Kotlin bridge (`io.mob.appupdate.MobAppUpdateBridge`),
  manifest permission `REQUEST_INSTALL_PACKAGES`, `MobAppUpdate.SelfTest`.
