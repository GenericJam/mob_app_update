# mob_app_update

Self-update for [Mob](https://github.com/GenericJam/mob) Android apps from
GitHub Releases. The app checks a repository's releases for a newer APK of
itself, downloads it with progress, verifies its sha256, and the user taps
Install in the system dialog. Nothing installs silently.

Android only. iOS apps update through TestFlight / the App Store; there every
call answers `{:error, :unsupported}`. The design and trust model are in
[`decisions/2026-11-13-app-update.md`](decisions/2026-11-13-app-update.md).

## Install

```elixir
# mix.exs
{:mob_app_update, github: "GenericJam/mob_app_update", ref: "<sha>"}
```

```elixir
# mob.exs
config :mob, :plugins, [:mob_app_update]
# Not on Hex and unsigned: acknowledge it (every build prints a banner).
config :mob, :acknowledge_unsafe_plugins, [:mob_app_update]
```

Then `mix mob.deploy --native`. Activation merges
`android.permission.REQUEST_INSTALL_PACKAGES` into the app's manifest and
compiles the zig NIF and the Kotlin bridge (`io.mob.appupdate.MobAppUpdateBridge`).

## Usage

```elixir
case MobAppUpdate.check(repo: "owner/app") do
  {:ok, :available, release} ->
    # release.version_name, release.notes (markdown), release.apk.size, ...
    Task.start(fn -> send(screen, {:downloaded, MobAppUpdate.download(release, notify: screen)}) end)

  {:ok, :up_to_date, %{installed: installed, latest: latest}} ->
    :up_to_date

  {:error, reason} ->
    # {:rate_limited, reset_at}, :no_release, :no_update_metadata, ...
    {:error, reason}
end
```

```elixir
# in the screen
def handle_info({:mob_app_update, {:progress, bytes, total}}, socket), do: ...

def handle_info({:downloaded, {:ok, apk}}, socket) do
  if MobAppUpdate.can_request_installs?() do
    :ok = MobAppUpdate.install(apk)          # system confirmation follows
  else
    # explain, then send the user to the "Install unknown apps" switch;
    # check can_request_installs?/0 again when the app resumes
    MobAppUpdate.open_install_settings()
  end
  ...
end

def handle_info({:mob_app_update, {:install, status}}, socket), do: ...
```

### API

| Function | Returns |
|---|---|
| `installed/0` | `{:ok, %{package, version_code, version_name}}` |
| `check(opts)` | `{:ok, :available, release}`, `{:ok, :up_to_date, %{installed, latest}}`, `{:error, reason}` |
| `download(release, opts)` | `{:ok, path}`, `{:error, {:sha256_mismatch, expected, got}}`, `{:error, {:size_mismatch, expected, got}}`, ... |
| `can_request_installs?/0` | `boolean` (`PackageManager.canRequestPackageInstalls`) |
| `open_install_settings/0` | `:ok` (opens `ACTION_MANAGE_UNKNOWN_APP_SOURCES` for this app) or `{:error, :not_ready \| :failed \| :unsupported}` |
| `install(path, opts)` | `:ok` (session started) or `{:error, :install_permission_required \| :invalid_apk \| {:not_an_update, installed_version_code, apk_version_code} \| {:package_mismatch, installed_package, apk_package} \| {:signature_mismatch, installed_signers, apk_signers}}` |

A `release`:

```elixir
%{tag: "v1.4.0", name: "1.4.0", notes: "markdown", published_at: ~U[...],
  html_url: "https://github.com/...", prerelease: false,
  version_code: 42, version_name: "1.4.0", package: "com.example.app",
  apk: %{name: "app.apk", url: "https://github.com/.../app.apk", size: 104857600, sha256: "..."}}
```

`check/1` options: `repo:` (required, `"owner/name"`), `prerelease:`
(`false`: GitHub's latest release only; `true`: the newest non-draft release
including pre-releases), `metadata_asset:` (`"update.json"`), `api_base:`
(`"https://api.github.com"`), `installed:` (override, for tests).

`download/2` options: `progress: fn bytes, total -> ... end`, `notify: pid`,
`dir:` (default: the app's `<cacheDir>/mob_app_update`, emptied each time the
app starts). It runs in the calling process; call it from a `Task`.

Network options for both: `cacerts:` (default: the OS store, else Android's
`/system/etc/security/cacerts`), `ssl:` (extra `:ssl` options),
`user_agent:` (`"mob_app_update"`), `timeout:` (ms; for a download, the
silence allowed between chunks; default 60 000), `connect_timeout:` (15 000).
GitHub allows 60 unauthenticated API requests per hour per IP; a check costs
one, so don't check on every screen mount.

Messages to the `notify:` process (default: the caller of `install/2`):

* `{:mob_app_update, {:progress, bytes, total}}`
* `{:mob_app_update, {:install, :pending_user_action}}` — the confirmation is on screen
* `{:mob_app_update, {:install, :success}}`
* `{:mob_app_update, {:install, {:failure, status, message}}}` — a
  `PackageInstaller.STATUS_*` code; 3 (`STATUS_FAILURE_ABORTED`) is the user
  cancelling

When the update installs, Android stops the running app to replace it, so
`:success` usually doesn't arrive; the user reopens the updated app. The APK
is deleted after a final status (and leftovers on the next start).

Before installing, `install/2` reads the APK with
`getPackageArchiveInfo(GET_SIGNING_CERTIFICATES)` and requires the same
package, a higher `versionCode` and the same signing certificates as the
installed app. Android enforces that too; checking first gives a clear error
and never shows the user a confirmation for an install that would fail.

## Publishing a release

Build and sign the APK as usual (the same key as the installed app; the
debug key for debug builds), then from the app's project:

```bash
mix mob_app_update.publish --repo owner/app --apk android/app/build/outputs/apk/release/app-release.apk \
  --tag v1.4.0 [--title "1.4.0"] [--notes-file NOTES.md] [--target <commitish>] \
  [--prerelease] [--draft] [--dry-run]
```

It reads package / versionCode / versionName with `aapt2 dump badging`,
verifies the signature with `apksigner verify --print-certs` (printing the
signer certificate's SHA-256), computes the sha256, writes `update.json` and
`<apk>.sha256`, and runs `gh release create` uploading the APK and both
files. `--target` creates a new tag at that commit instead of the default
branch's tip (`gh release create --target`). `--dry-run` prints the `gh`
command instead. The build-tools are found
under `ANDROID_HOME` / `ANDROID_SDK_ROOT` / `~/Library/Android/sdk`
(`MOB_APP_UPDATE_AAPT2` / `MOB_APP_UPDATE_APKSIGNER` override them). The
task never touches signing keys.

Bump `versionCode` for every release: it is what apps compare.

### Release metadata (`update.json`)

```json
{"package": "com.example.app", "version_code": 42, "version_name": "1.4.0",
 "apk": "app-release.apk", "sha256": "<64 hex>", "size": 104857600}
```

The APK asset named by `apk` must be in the same release with that size; when
GitHub reports the asset's `digest` (`sha256:<hex>`) it must equal `sha256`.
Releases without `update.json` are not offered.

## Development

```bash
mix setup     # deps + git hooks
mix format && mix credo --strict && mix compile --warnings-as-errors && mix test
```

The tests run on the host: release parsing and selection, the download
against a local HTTP server, the install pre-check and the publish task with
stub `aapt2` / `apksigner`. The native side needs a device; see
[AGENTS.md](AGENTS.md).

## License

MIT
