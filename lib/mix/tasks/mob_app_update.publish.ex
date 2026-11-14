defmodule Mix.Tasks.MobAppUpdate.Publish do
  @shortdoc "Publishes a signed APK as a GitHub release that MobAppUpdate offers as an update"

  @moduledoc """
  Publishes a signed APK as a GitHub release carrying the update metadata
  `MobAppUpdate.check/1` reads.

      mix mob_app_update.publish --repo owner/app --apk path/to/app.apk --tag v1.4.0 \\
        [--title "1.4.0"] [--notes-file NOTES.md] [--target COMMITISH] [--prerelease] [--draft] \\
        [--dry-run] [--out DIR]

  It:

    1. reads the APK's package, `versionCode` and `versionName` with `aapt2
       dump badging` (Android SDK build-tools),
    2. verifies the APK signature with `apksigner verify --print-certs` and
       prints each signer certificate's SHA-256 (it must be the key the
       installed app is signed with, or Android refuses the update),
    3. computes the APK's sha256 and writes `update.json` and `<apk>.sha256`
       to `--out` (default: a directory under the system temp dir),
    4. runs `gh release create <tag> <apk> update.json <apk>.sha256 --repo
       <repo> ...`, which needs an authenticated `gh` (`gh auth login`).

  `--dry-run` does steps 1–3 and prints the `gh` command instead of running
  it. The task never touches signing keys: sign the APK first (your release
  build, or `apksigner sign`).

  `update.json`:

      {"package": "com.example.app", "version_code": 42, "version_name": "1.4.0",
       "apk": "app.apk", "sha256": "<64 hex>", "size": 104857600}

  `--prerelease` releases are offered only to apps that call `check/1` with
  `prerelease: true`; `--draft` releases are invisible to apps until you
  publish them on GitHub. `--target` is passed to `gh release create
  --target`: the commit (or branch) a new tag is created at, instead of the
  default branch's tip; it has no effect when the tag already exists.

  Tools are found under `ANDROID_HOME`, `ANDROID_SDK_ROOT`,
  `~/Library/Android/sdk` or `~/Android/Sdk` (newest `build-tools/*`), then
  on `PATH`. `MOB_APP_UPDATE_AAPT2` / `MOB_APP_UPDATE_APKSIGNER` override
  them with explicit paths.
  """
  use Mix.Task

  @switches [
    repo: :string,
    apk: :string,
    tag: :string,
    title: :string,
    notes_file: :string,
    prerelease: :boolean,
    draft: :boolean,
    dry_run: :boolean,
    out: :string,
    target: :string
  ]

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)
    repo = required(opts, :repo)
    apk = required(opts, :apk)
    tag = required(opts, :tag)

    unless repo =~ ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z},
      do: Mix.raise("--repo must be owner/name, got: #{repo}")

    unless File.regular?(apk), do: Mix.raise("--apk: no such file: #{apk}")

    if notes = opts[:notes_file] do
      unless File.regular?(notes), do: Mix.raise("--notes-file: no such file: #{notes}")
    end

    asset = Path.basename(apk)

    # GitHub renames asset files with other characters; the metadata must name
    # the asset exactly.
    unless asset =~ ~r/\A[A-Za-z0-9._-]+\.apk\z/,
      do:
        Mix.raise(
          "the APK file name must match [A-Za-z0-9._-]+.apk (GitHub would rename it), got: #{asset}"
        )

    badging = badging(apk)
    signers = signers(apk)
    sha256 = sha256(apk)
    size = File.stat!(apk).size

    metadata = %{
      "package" => badging.package,
      "version_code" => badging.version_code,
      "version_name" => badging.version_name,
      "apk" => asset,
      "sha256" => sha256,
      "size" => size
    }

    out = opts[:out] || Path.join(System.tmp_dir!(), "mob_app_update-#{badging.package}-#{tag}")
    File.mkdir_p!(out)
    metadata_path = Path.join(out, "update.json")
    sha_path = Path.join(out, asset <> ".sha256")
    File.write!(metadata_path, JSON.encode!(metadata) <> "\n")
    File.write!(sha_path, "#{sha256}  #{asset}\n")

    shell = Mix.shell()
    shell.info("Package:   #{badging.package}")
    shell.info("Version:   #{badging.version_name} (versionCode #{badging.version_code})")
    shell.info("APK:       #{asset} (#{size} bytes)")
    shell.info("SHA-256:   #{sha256}")
    Enum.each(signers, &shell.info("Signer certificate SHA-256: #{&1}"))
    shell.info("Metadata:  #{metadata_path}")

    gh_args = gh_args(tag, repo, [apk, metadata_path, sha_path], opts)

    if opts[:dry_run] do
      shell.info("Dry run; would run: gh #{Enum.map_join(gh_args, " ", &quote_arg/1)}")
    else
      gh = System.find_executable("gh") || Mix.raise("gh (GitHub CLI) not found on PATH")

      case System.cmd(gh, gh_args, stderr_to_stdout: true) do
        {output, 0} -> shell.info(String.trim(output))
        {output, status} -> Mix.raise("gh release create failed (exit #{status}):\n#{output}")
      end
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> opts
      {_, rest, []} -> Mix.raise("unexpected arguments: #{Enum.join(rest, " ")}")
      {_, _, invalid} -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp required(opts, key) do
    opts[key] || Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
  end

  defp gh_args(tag, repo, files, opts) do
    notes =
      case opts[:notes_file] do
        nil -> ["--notes", ""]
        file -> ["--notes-file", file]
      end

    ["release", "create", tag | files] ++
      ["--repo", repo, "--title", opts[:title] || tag] ++
      notes ++
      if(opts[:target], do: ["--target", opts[:target]], else: []) ++
      if(opts[:prerelease], do: ["--prerelease"], else: []) ++
      if(opts[:draft], do: ["--draft"], else: [])
  end

  defp quote_arg(""), do: ~s("")

  defp quote_arg(arg) do
    if arg =~ ~r/\A[A-Za-z0-9_\/.:=@%+,-]+\z/,
      do: arg,
      else: "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp badging(apk) do
    aapt2 = tool("aapt2", "MOB_APP_UPDATE_AAPT2")
    output = run_tool(aapt2, ["dump", "badging", apk])

    with [line | _] <- Regex.run(~r/^package:.*$/m, output),
         [_, package] <- Regex.run(~r/ name='([^']+)'/, line),
         [_, code] <- Regex.run(~r/ versionCode='(\d+)'/, line) do
      version_name =
        case Regex.run(~r/ versionName='([^']*)'/, line) do
          [_, name] -> name
          nil -> ""
        end

      %{package: package, version_code: String.to_integer(code), version_name: version_name}
    else
      _ -> Mix.raise("could not read package/versionCode from aapt2 output:\n#{output}")
    end
  end

  defp signers(apk) do
    apksigner = tool("apksigner", "MOB_APP_UPDATE_APKSIGNER")
    output = run_tool(apksigner, ["verify", "--print-certs", apk])

    case Regex.scan(~r/certificate SHA-256 digest: ([0-9a-fA-F]{64})/, output) do
      [] -> Mix.raise("apksigner printed no signer certificate:\n#{output}")
      matches -> matches |> Enum.map(fn [_, hex] -> String.downcase(hex) end) |> Enum.uniq()
    end
  end

  defp run_tool(path, args) do
    case System.cmd(path, args, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        Mix.raise("#{Path.basename(path)} #{hd(args)} failed (exit #{status}):\n#{output}")
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp tool(name, env) do
    case System.get_env(env) do
      nil ->
        find_in_sdk(name) || System.find_executable(name) ||
          Mix.raise(
            "#{name} not found: install the Android SDK build-tools, set ANDROID_HOME, or set #{env}"
          )

      path ->
        path
    end
  end

  defp find_in_sdk(name) do
    sdk_roots()
    |> Enum.flat_map(fn root -> Path.wildcard(Path.join([root, "build-tools", "*", name])) end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.max_by(&build_tools_version/1, &>=/2, fn -> nil end)
  end

  defp build_tools_version(path) do
    dir = path |> Path.dirname() |> Path.basename()

    case Version.parse(dir) do
      {:ok, version} -> {1, version.major, version.minor, version.patch}
      :error -> {0, 0, 0, 0}
    end
  end

  defp sdk_roots do
    home = System.user_home() || ""

    [
      System.get_env("ANDROID_HOME"),
      System.get_env("ANDROID_SDK_ROOT"),
      Path.join(home, "Library/Android/sdk"),
      Path.join(home, "Android/Sdk")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end
end
