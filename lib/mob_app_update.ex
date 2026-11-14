defmodule MobAppUpdate do
  @moduledoc """
  Self-update for Mob Android apps from GitHub Releases — a Mob plugin.

  The app checks a repository's releases for a newer APK of itself, downloads
  it (streamed to the app's cache directory, with progress), verifies its size
  and sha256, and hands it to Android's `PackageInstaller`. The user always
  confirms the install in the system dialog; nothing installs silently.
  Android only: iOS apps update through TestFlight / the App Store, and every
  call answers `{:error, :unsupported}` there (and on a host).

  ## Flow

      with {:ok, :available, release} <- MobAppUpdate.check(repo: "owner/app"),
           {:ok, apk} <- MobAppUpdate.download(release, notify: self()) do
        if MobAppUpdate.can_request_installs?(),
          do: MobAppUpdate.install(apk),
          else: MobAppUpdate.open_install_settings()
      end

  `download/2` and `install/2` report to a process:

    * `{:mob_app_update, {:progress, bytes, total}}` while downloading
    * `{:mob_app_update, {:install, :pending_user_action}}` — the system
      confirmation is on screen
    * `{:mob_app_update, {:install, :success}}`
    * `{:mob_app_update, {:install, {:failure, status, message}}}` — a
      `PackageInstaller.STATUS_*` code (3 = the user cancelled)

  When an update installs, Android stops the running app to replace it, so
  `:success` usually never arrives: the user reopens the updated app.

  ## Releases

  A release offers an update when it carries the metadata asset (default
  `update.json`, see `MobAppUpdate.Release`) next to the APK. Publish one with
  `mix mob_app_update.publish`. By default only GitHub's *latest* release
  (newest non-draft, non-prerelease) is considered; `prerelease: true` takes
  the newest non-draft release including pre-releases, for testers.

  ## Network options

  `check/1` and `download/2` take `:cacerts`, `:ssl`, `:user_agent`,
  `:timeout` and `:connect_timeout` (see the README). TLS uses OTP's `:ssl`;
  on Android the trust store is read from `/system/etc/security/cacerts`.
  Every URL, including each redirect hop, must be `https://`; anything else
  is `{:error, {:insecure_url, url}}`. `allow_loopback_http: true` also
  accepts `http://` to `127.0.0.1`, `::1` and `localhost` (tests, `adb
  reverse`), never another host.

  ## Size cap

  `check/1`, `download/2` and `install/2` take `:max_size` (bytes, default
  300 MiB): a release whose APK is larger is `{:error, {:apk_too_large,
  size, max_size}}`, and a download never writes more than that.
  `download/2` and `install/2` also require room for the APK plus 64 MiB
  before writing it: `{:error, {:insufficient_space, needed, free}}`.
  """

  alias MobAppUpdate.{Download, GitHub, Install, Native, Release}

  @typedoc "The installed app."
  @type installed :: Release.installed()

  @typedoc "An update candidate."
  @type release :: Release.t()

  @doc """
  The installed app's package name, `versionCode` and `versionName`.
  `{:error, :unsupported}` off Android.
  """
  @spec installed() :: {:ok, installed()} | {:error, :unsupported | term()}
  def installed do
    with {:ok, info} <- Native.info() do
      {:ok, Map.take(info, [:package, :version_code, :version_name])}
    end
  end

  @doc """
  Checks `repo`'s GitHub releases for an update.

  Options:

    * `:repo` (required) — `"owner/name"`
    * `:prerelease` — `false` (default): `GET /repos/:repo/releases/latest`,
      which must carry the metadata asset (else `{:error,
      :no_update_metadata}`; no release at all is `{:error, :no_release}`).
      `true`: the newest non-draft release of `GET /repos/:repo/releases`
      (pre-releases included) that carries the metadata asset; releases
      without it are skipped.
    * `:metadata_asset` — default `"update.json"`
    * `:api_base` — default `"https://api.github.com"`
    * `:installed` — the installed app (`installed/0`'s map); defaults to
      `installed/0`. For tests and host tools.
    * `:max_size` — the APK size cap (moduledoc)
    * network options (moduledoc)

  Returns `{:ok, :available, release}` when the release's `version_code` is
  higher than the installed `versionCode`, `{:ok, :up_to_date, %{installed:,
  latest: release | nil}}` otherwise. Errors include
  `{:package_mismatch, installed_package, release_package}`,
  `{:metadata_mismatch, detail}`, `{:invalid_metadata, field}` and
  `{:apk_too_large, size, max_size}` (see `MobAppUpdate.Release.build/3`),
  `{:rate_limited, reset_at}` (`reset_at` a `DateTime` or `nil`),
  `:not_found` (unknown repo), `{:bad_response, :latest | :releases |
  :metadata_asset}` (GitHub's JSON isn't shaped as documented),
  `{:insecure_url, url}`, `{:too_large, bytes_read}` (an API or metadata
  body over its cap) and `:unsupported` (no `:installed` off Android).
  """
  @spec check(keyword()) ::
          {:ok, :available, release()}
          | {:ok, :up_to_date, %{installed: installed(), latest: release() | nil}}
          | {:error, term()}
  def check(opts) do
    repo = Keyword.fetch!(opts, :repo)

    with :ok <- validate_repo(repo),
         {:ok, installed} <- installed_for(opts),
         {:ok, candidate} <- GitHub.candidate(repo, opts) do
      compare(candidate, installed, opts)
    end
  end

  defp compare(nil, installed, _opts),
    do: {:ok, :up_to_date, %{installed: installed, latest: nil}}

  defp compare(candidate, installed, opts) do
    with {:ok, metadata} <- GitHub.metadata(candidate, opts),
         {:ok, release} <- Release.build(candidate, metadata, opts) do
      Release.compare(release, installed)
    end
  end

  defp validate_repo(repo) do
    if is_binary(repo) and repo =~ ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z},
      do: :ok,
      else: {:error, {:invalid_repo, repo}}
  end

  defp installed_for(opts) do
    case Keyword.fetch(opts, :installed) do
      {:ok, installed} -> {:ok, installed}
      :error -> installed()
    end
  end

  @doc """
  Downloads `release`'s APK and verifies it; returns its path.

  The APK streams to a file (never into memory), by default in the app's
  `<cacheDir>/mob_app_update` (emptied each time the app starts). GitHub's
  redirect to its asset host is followed. The size and sha256 must match the
  release metadata; otherwise the file is deleted and the result is
  `{:error, {:size_mismatch, expected, got}}` or
  `{:error, {:sha256_mismatch, expected, got}}`. Before anything is
  requested, the size must be within `:max_size` (`{:error, {:apk_too_large,
  size, max_size}}`) and the directory must have room for it plus 64 MiB
  (`{:error, {:insufficient_space, needed, free}}`; not checked off Android).
  Transport errors are `{:error, reason}` (e.g. `:timeout`,
  `{:insecure_url, url}`, `{:http_status, status}`, `:not_found`); file
  errors are `{:error, {:file, posix}}`.

  Runs in the calling process until the download ends: call it from a `Task`
  and pass `notify:` the screen's pid.

  Options:

    * `:progress` — `fn bytes, total -> ... end`, called as data arrives
    * `:notify` — a pid sent `{:mob_app_update, {:progress, bytes, total}}`
    * `:dir` — where to write (default: the app's cache dir; a temp dir off
      Android)
    * `:max_size` — the APK size cap (moduledoc)
    * network options (moduledoc); `:timeout` is the silence allowed between
      chunks
  """
  @spec download(release(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def download(release, opts \\ []), do: Download.run(release, opts)

  @doc """
  Whether the user has allowed this app to install apps
  (`PackageManager.canRequestPackageInstalls`, the "Install unknown apps"
  setting). `false` off Android.
  """
  @spec can_request_installs?() :: boolean()
  def can_request_installs?, do: Native.can_request_installs?()

  @doc """
  Opens the system "Install unknown apps" setting for this app
  (`Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`). Call it after explaining why
  when `can_request_installs?/0` is `false`, then check again when the app
  resumes.
  """
  @spec open_install_settings() :: :ok | {:error, term()}
  def open_install_settings, do: Native.open_install_settings()

  @doc """
  Installs the APK at `path` (from `download/2`) as an update of this app,
  after the user confirms it in the system dialog.

  Before opening the install session it reads the APK with
  `PackageManager.getPackageArchiveInfo` and requires the same package, a
  higher `versionCode` and signing certificates Android accepts as an update
  of the installed app (`MobAppUpdate.Precheck`):

    * `{:error, {:package_mismatch, installed, apk}}`
    * `{:error, {:not_an_update, installed_version_code, apk_version_code}}`
    * `{:error, {:signature_mismatch, installed_signers, apk_signers}}`
    * `{:error, :invalid_apk}` — Android can't parse it
    * `{:error, :install_permission_required}` — see `open_install_settings/0`
    * `{:error, {:apk_too_large, size, max_size}}` — over `:max_size`
    * `{:error, {:insufficient_space, needed, free}}` — no room for the
      installer's copy (plus 64 MiB)
    * `{:error, {:no_such_file, path}}`

  The checked bytes are the installed bytes: an APK directly in the app's
  private download dir (where `download/2` puts it) is used in place; any
  other path is first copied there, and the copy is checked and installed
  (the original is left alone).

  `:ok` means the session is starting; the outcome arrives as
  `{:mob_app_update, {:install, status}}` messages (moduledoc) to
  `opts[:notify]` (default: the caller). The APK in the download dir is
  deleted once the install reaches a final status.
  """
  @spec install(Path.t(), keyword()) ::
          :ok
          | {:error,
             :unsupported
             | :install_permission_required
             | :invalid_apk
             | {:not_an_update, integer(), integer()}
             | {:package_mismatch, String.t(), String.t()}
             | {:signature_mismatch, [String.t()], [String.t()]}
             | {:apk_too_large, pos_integer(), pos_integer()}
             | {:insufficient_space, pos_integer(), non_neg_integer()}
             | term()}
  def install(path, opts \\ []), do: Install.run(IO.chardata_to_string(path), opts)
end
