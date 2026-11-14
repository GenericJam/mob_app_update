# Changelog

## [Unreleased]

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
