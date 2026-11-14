# mob_app_update

Self-update for [Mob](https://github.com/GenericJam/mob) Android apps from
GitHub Releases. The app checks a repository's releases for a newer APK of
itself, downloads it with progress, verifies its sha256, and the user taps
Install in the system dialog. Nothing installs silently.

Android only, `minSdk` 28 or higher (Mob's default; the signer check uses
`GET_SIGNING_CERTIFICATES`). iOS apps update through TestFlight / the App
Store; there every call answers `{:error, :unsupported}`. The design and
trust model are in
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
| `check(opts)` | `{:ok, :available, release}`, `{:ok, :up_to_date, %{installed, latest}}`, `{:error, reason}`: `:no_release`, `:no_update_metadata`, `:not_found`, `{:rate_limited, reset_at \| nil}`, `{:package_mismatch, installed, release}`, `{:invalid_metadata, field}`, `{:metadata_mismatch, detail}`, `{:apk_too_large, size, max_size}`, `{:bad_response, :latest \| :releases \| :metadata_asset}`, `{:insecure_url, url}`, `{:too_large, bytes_read}`, transport errors |
| `download(release, opts)` | `{:ok, path}`, `{:error, {:sha256_mismatch, expected, got}}`, `{:error, {:size_mismatch, expected, got}}`, `{:error, {:apk_too_large, size, max_size}}`, `{:error, {:insufficient_space, needed, free}}`, `{:error, {:file, posix}}`, transport errors (`:timeout`, `:not_found`, `{:http_status, status}`, `{:insecure_url, url}`, ...) |
| `can_request_installs?/0` | `boolean` (`PackageManager.canRequestPackageInstalls`) |
| `open_install_settings/0` | `:ok` (opens `ACTION_MANAGE_UNKNOWN_APP_SOURCES` for this app) or `{:error, :not_ready \| :failed \| :unsupported}` |
| `install(path, opts)` | `:ok` (session started) or `{:error, :install_permission_required \| :invalid_apk \| {:not_an_update, installed_version_code, apk_version_code} \| {:package_mismatch, installed_package, apk_package} \| {:signature_mismatch, installed_signers, apk_signers} \| {:apk_too_large, size, max_size} \| {:insufficient_space, needed, free} \| {:no_such_file, path}}` |

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
(`"https://api.github.com"`), `installed:` (override, for tests),
`max_size:`.

`download/2` options: `progress: fn bytes, total -> ... end`, `notify: pid`,
`dir:` (default: the app's `<cacheDir>/mob_app_update`, emptied each time the
app starts), `max_size:`. It runs in the calling process; call it from a
`Task`.

`max_size:` (`check/1`, `download/2`, `install/2`) caps the APK at that many
bytes, default 300 MiB. The metadata's `size` and the release asset's size
are written by whoever publishes the release, so they agreeing is no limit;
the cap is checked against the metadata and again against the streamed
bytes, which are cut off at the metadata size. `download/2` and `install/2`
(whose installer session makes a second copy) also require free space for
the APK plus 64 MiB on Android: `{:error, {:insufficient_space, needed,
free}}`.

Network options for both: `cacerts:` (default: the OS store, else Android's
`/system/etc/security/cacerts`), `ssl:` (extra `:ssl` options),
`user_agent:` (`"mob_app_update"`), `timeout:` (ms; for a download, the
silence allowed between chunks; default 60 000), `connect_timeout:` (15 000),
`allow_loopback_http:` (`false`). Every URL and every redirect hop must be
`https://` (`{:error, {:insecure_url, url}}` otherwise);
`allow_loopback_http: true` also accepts `http://` to `127.0.0.1`, `::1` or
`localhost` (tests, `adb reverse`), never another host.
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
in the download dir is deleted after a final status (and leftovers on the
next start; a failed delete is logged).

Before installing, `install/2` reads the APK with
`getPackageArchiveInfo(GET_SIGNING_CERTIFICATES)` and requires the same
package, a higher `versionCode` and signers Android accepts as an update:
the same certificate set, or, for a single signer, a rotation lineage
linking the two (the installed signer in the APK's lineage, or the APK's
signer in the installed app's lineage). The SDK doesn't expose a lineage's
capability flags, so for a rotated key Android has the last word at install
time (a refusal arrives as `{:install, {:failure, status, message}}`).
Android enforces all of it too; checking first gives a clear error.

The checked bytes are the installed bytes: an APK directly in the app's
private download dir (where `download/2` puts it) is used in place; any
other path (shared storage, a `dir:` of your own) is first copied there,
and the copy is checked, installed and deleted; your original stays.

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
task never touches signing keys. `--tag` must be a plain git tag name
(`/`-separated `[A-Za-z0-9_][A-Za-z0-9._+-]*` components, no `..`, none
ending in `.` or `.lock`); `gh` gets every option as `--name=value` and the
tag and files after `--`, and paths containing `#` are refused (`gh` would
read `file#label`).

Bump `versionCode` for every release: it is what apps compare.

### Release metadata (`update.json`)

```json
{"package": "com.example.app", "version_code": 42, "version_name": "1.4.0",
 "apk": "app-release.apk", "sha256": "<64 hex>", "size": 104857600}
```

The APK asset named by `apk` must be in the same release with that size; when
GitHub reports the asset's `digest` (`sha256:<hex>`) it must equal `sha256`.
Releases without `update.json` are not offered, nor releases whose `size` is
over the app's `max_size:` (default 300 MiB).

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
