defmodule MobAppUpdate.Install do
  @moduledoc false
  # MobAppUpdate.install/2: binds the pre-check to the bytes the installer
  # session receives. PackageManager reads the APK by path, and the bridge
  # reopens that path later on its worker thread; a file anyone else can
  # write (shared storage, a world-writable dir) could be swapped in between.
  # So the APK must live in the app's private download dir (only this app's
  # uid can change it): a regular file directly in `download_dir` is used in
  # place; anything else is first copied there under a fresh name, and the
  # copy is what gets checked, installed and deleted. The caller's original
  # file is left alone.

  alias MobAppUpdate.{Download, Native, Precheck, Release}

  @spec run(Path.t(), keyword()) :: :ok | {:error, term()}
  def run(path, opts) do
    notify = Keyword.get(opts, :notify, self())
    max = Release.max_size(opts)

    with {:ok, installed} <- Native.info(),
         {:ok, apk_path, size, staged?} <- stage(path, installed.download_dir, max) do
      result =
        with {:ok, apk} <- Native.inspect_apk(apk_path),
             :ok <- Precheck.verify(installed, apk),
             # The session copy goes to /data like the download dir.
             :ok <- Download.require_space(installed.download_dir, size),
             :ok <- require_install_permission() do
          Native.install(apk_path, notify)
        end

      # Once the bridge has the session, it deletes the APK at a final status.
      if result != :ok and staged?, do: Download.remove(apk_path)
      result
    end
  end

  @doc false
  # {:ok, private_path, size, copied?}. Public for the host tests.
  @spec stage(Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t(), non_neg_integer(), boolean()} | {:error, term()}
  def stage(path, dir, max) do
    path = Path.expand(path)
    dir = Path.expand(dir)

    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} ->
        if Path.dirname(path) == dir,
          do: in_place(path, size, max),
          else: copy(path, size, dir, max)

      {:ok, %{type: :symlink}} ->
        case File.stat(path) do
          {:ok, %{type: :regular, size: size}} -> copy(path, size, dir, max)
          _ -> {:error, {:no_such_file, path}}
        end

      _ ->
        {:error, {:no_such_file, path}}
    end
  end

  defp in_place(path, size, max) do
    with :ok <- Release.check_cap(size, max), do: {:ok, path, size, false}
  end

  defp copy(src, size, dir, max) do
    dest =
      Path.join(dir, "install-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}.apk")

    with :ok <- Release.check_cap(size, max),
         :ok <- mkdir(dir),
         :ok <- Download.require_space(dir, size),
         {:ok, copied} <- copy_bytes(src, dest, max) do
      case Release.check_cap(copied, max) do
        :ok ->
          {:ok, dest, copied, true}

        error ->
          Download.remove(dest)
          error
      end
    end
  end

  # At most max + 1 bytes, so a file that grows after the stat still can't
  # fill the disk; the caller refuses anything over max.
  defp copy_bytes(src, dest, max) do
    with {:ok, input} <- open(src, [:read, :binary, :raw]) do
      result =
        case open(dest, [:write, :exclusive, :binary, :raw]) do
          {:ok, output} ->
            copied = :file.copy(input, output, max + 1)

            case {copied, File.close(output)} do
              {{:ok, bytes}, :ok} ->
                {:ok, bytes}

              {{:error, reason}, _} ->
                Download.remove(dest)
                {:error, {:file, reason}}

              {_, {:error, reason}} ->
                Download.remove(dest)
                {:error, {:file, reason}}
            end

          error ->
            error
        end

      File.close(input)
      result
    end
  end

  defp open(path, modes) do
    case File.open(path, modes) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp require_install_permission do
    if Native.can_request_installs?(), do: :ok, else: {:error, :install_permission_required}
  end
end
