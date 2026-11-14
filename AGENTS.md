# mob_app_update — Agent Instructions

You're in **mob_app_update**, a Mob capability plugin: self-update for
Android apps from GitHub Releases (check → download + sha256 → user-confirmed
`PackageInstaller` install). Public API: `MobAppUpdate.{installed/0, check/1,
download/2, can_request_installs?/0, open_install_settings/0, install/2}`,
plus `mix mob_app_update.publish`. Design record and trust model:
[`decisions/2026-11-13-app-update.md`](decisions/2026-11-13-app-update.md).

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view
and the cross-cutting rules, and [`~/code/mob/MOB_PLUGINS.md`](../mob/MOB_PLUGINS.md)
for the manifest schema. This file is mob_app_update-specific.

> **Keep this file current.** When you change the API shape, the bridge
> contract or hit a gotcha that would trip the next agent, fix it here in the
> same commit.

## What it is NOT

* **Not iOS.** No iOS native code; every call answers `{:error, :unsupported}`
  off Android. iOS updates go through TestFlight / the App Store.
* **Not `mob_deliver`.** mob_deliver pushes signed BEAM/screen updates over
  the air into a running app; this replaces the whole APK through Android's
  installer.
* **Not a silent installer.** Every install goes through the system
  confirmation. Don't add `USER_ACTION_NOT_REQUIRED` or anything that skips it.

## Layout

* `lib/mob_app_update.ex` — public API; orchestrates the rest.
* `lib/mob_app_update/release.ex` — pure: GitHub release JSON + `update.json`
  → release map; selection (`pick/2`), validation (`build/2`), `compare/2`.
* `lib/mob_app_update/github.ex` — the two GitHub reads (API + metadata asset).
* `lib/mob_app_update/http.ex` — `:httpc` + `:ssl`: small GETs, streaming GET
  with flow control (`{:self, :once}`), manual redirects, CA store (Android
  fallback `/system/etc/security/cacerts`).
* `lib/mob_app_update/download.ex` — streams to `<dir>/<apk>.part`, hashes,
  checks size + sha256, renames; deletes on any failure.
* `lib/mob_app_update/precheck.ex` — pure install pre-check (package,
  versionCode, signer set / v3 rotation).
* `lib/mob_app_update/native.ex` — the NIF seam; JSON decode; `:unsupported`
  off Android.
* `lib/mob_app_update/self_test.ex` — `Mob.Plugin.SelfTest` (installed/0 round trip).
* `lib/mix/tasks/mob_app_update.publish.ex` — host-side publish task (aapt2,
  apksigner, `gh release create`).
* `src/mob_app_update_nif.erl` — Erlang NIF stub (tolerant `on_load`).
* `priv/mob_plugin.exs` — manifest: Android zig NIF, Kotlin bridge,
  `REQUEST_INSTALL_PACKAGES`.
* `priv/native/jni/mob_app_update_nif.zig` — NIFs (all dirty IO) +
  `nativeRegister` / `nativeDeliverInstall` thunks.
* `priv/native/android/MobAppUpdateBridge.kt` — `MobActivityAware` bridge:
  PackageManager info / archive info, unknown-sources settings,
  PackageInstaller session + status receiver.

## Load-bearing invariants

1. **Decisions live in Elixir.** The bridge only reports (JSON) and executes;
   package / versionCode / signer comparisons are in `Precheck` and
   `Release`, where host tests cover them. Keep it that way.
2. **The bridge contract is three files.** Method names + JNI signatures in
   `nativeRegister` (zig), the `@JvmStatic` methods (Kotlin), the stub
   (Erlang). Return codes `OK/ERR_NOT_READY/ERR_FAILED` are mirrored in zig's
   `codeResult`; status -1 / 0 / other in `nativeDeliverInstall`.
3. **Text crosses JNI as UTF-8 `byte[]`** (paths, JSON, messages), never via
   `NewStringUTF` / `GetStringUTFChars` (modified UTF-8).
4. **No pending Java exception on a BEAM thread**: every call is followed by
   `clearPendingException`. The Kotlin side catches what it can too.
5. **Nothing heavy on a scheduler or the UI thread.** NIFs are dirty IO
   (archive parsing verifies the whole APK); the session copy runs on the
   bridge's single worker thread.
6. **The status PendingIntent is explicit and mutable** (`setPackage`,
   `FLAG_MUTABLE`; API 34 forbids mutable implicit ones) and its receiver is
   registered `RECEIVER_NOT_EXPORTED` on 33+. Below 33 a runtime receiver is
   exported, so it ignores any broadcast without the per-process `EXTRA_TOKEN`
   the PendingIntent carries: otherwise another app could hand us an
   `EXTRA_INTENT` to start. Keep that check first in `onReceive`.
7. **An update that installs kills the app**, so `:success` usually never
   arrives and the APK is cleaned on the next start (`setActivity`, once per
   process). Don't build flows that wait for `:success`.
8. **32-bit Android is a target**: pids travel as `jlong` via
   `pidToJlong` / `pidFromLong`.

## Testing

```bash
mix format && mix credo --strict && mix compile --warnings-as-errors && mix test
```

Host tests: `Release` (selection, validation, compare), `check/1` and
`download/2` against `test/support/test_server.ex` (a tiny `:gen_tcp` HTTP
server: redirects, rate limit, progress, mismatches), `Precheck`, the publish
task with stub tools (`MOB_APP_UPDATE_AAPT2` / `MOB_APP_UPDATE_APKSIGNER`),
and the manifest through mob_dev's validator.

Native code isn't exercised by `mix test`. Device recipe (Android emulator;
lease it first, see `~/AGENTS.md`):

* A throwaway `mix mob.new <host> --android --blank` with
  `{:mob_app_update, path: "<checkout>"}` (the checkout dir must be named
  `mob_app_update`: mob_dev derives the plugin name from it; delete a stale
  gitignored `priv/mob_plugin.sig`), `config :mob, :plugins,
  [:mob_app_update]` and `config :mob, :acknowledge_unsafe_plugins,
  [:mob_app_update]`. `mix mob.install`, then `mix mob.deploy --native
  --device <serial>` with zig 0.17.0 first on `PATH`.
* Build variant APKs by editing `versionCode` in `android/app/build.gradle`
  and running `./gradlew assembleDebug` in `android/`; re-sign a copy with a
  throwaway keystore (`apksigner sign`) for the signature-mismatch case.
* Drive it with `mix mob.connect` / `:rpc` (or `adb shell` for settings): the
  first `can_request_installs?/0` is `false`; `open_install_settings/0` opens
  the switch; after allowing, `install/2` brings up the confirmation; tap
  Install (`adb shell input tap` / uiautomator) and check `dumpsys package
  <pkg> | grep versionCode`.

## Pre-commit + release

Same gate as mob (above), plus `zig fmt priv/native/jni/*.zig` and a device
check for native changes. Not published to Hex; apps depend on a git ref.
Don't add a Hex release workflow and don't bump the version.
