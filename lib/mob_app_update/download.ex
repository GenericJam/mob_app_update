defmodule MobAppUpdate.Download do
  @moduledoc false
  # Streams a release's APK to `<dir>/<apk name>.part`, hashing as it goes,
  # then checks size + sha256 and renames it to `<dir>/<apk name>`. Any failure
  # deletes the partial file (a failed delete is logged). Runs in the caller's
  # process.
  #
  # The release's size is capped (Release.max_size/1) before anything is
  # requested, and the stream is cut off as soon as it passes that size, so a
  # release can't make the app write more than the cap. The directory must
  # have room for the APK plus @reserve first.

  require Logger

  alias MobAppUpdate.{HTTP, Native, Release}

  # Progress is reported at most once per this many bytes (plus the start
  # and the end), so a 100 MB APK sends a few hundred messages, not thousands.
  @progress_step 256 * 1024

  # Left free for the system after an APK is written: Android starts failing
  # installs and other apps' writes when storage runs out.
  @reserve 64 * 1024 * 1024

  @spec run(MobAppUpdate.Release.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def run(%{apk: %{name: name, url: url, size: size, sha256: sha256}}, opts) do
    with :ok <- Release.check_cap(size, Release.max_size(opts)),
         {:ok, dir} <- dir(opts),
         :ok <- mkdir(dir),
         :ok <- require_space(dir, size) do
      dest = Path.join(dir, Path.basename(name))
      part = dest <> ".part"
      report = reporter(opts, size)

      result =
        case File.open(part, [:write, :binary, :raw]) do
          {:ok, io} -> fetch(url, io, size, report, opts)
          {:error, reason} -> {:error, {:file, reason}}
        end

      finish(result, part, dest, size, sha256)
    end
  end

  @doc false
  # :ok when `dir`'s file system has room for `bytes` plus the reserve,
  # else {:error, {:insufficient_space, needed, free}}. Off Android (no
  # bridge to ask) the check is skipped.
  @spec require_space(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def require_space(dir, bytes) do
    case Native.free_space(dir) do
      {:ok, free} -> space(free, bytes)
      {:error, :unsupported} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec space(non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def space(free, bytes) do
    needed = bytes + @reserve
    if free >= needed, do: :ok, else: {:error, {:insufficient_space, needed, free}}
  end

  @doc false
  # Deletes `path`, logging a failure other than "already gone".
  @spec remove(Path.t()) :: :ok
  def remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("mob_app_update: could not delete #{path}: #{reason}")
    end

    :ok
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp fetch(url, io, size, report, opts) do
    state = %{io: io, hash: :crypto.hash_init(:sha256), bytes: 0, reported: 0, size: size}
    report.(0)

    result =
      HTTP.stream(url, opts, state, fn {:data, chunk}, state ->
        write_chunk(state, chunk, report)
      end)

    case {result, File.close(io)} do
      {{:ok, state}, :ok} -> {:ok, state}
      {{:ok, _state}, {:error, reason}} -> {:error, {:file, reason}}
      {error, _} -> error
    end
  end

  # Don't let a wrong or hostile server fill the disk: size is at most the cap.
  defp write_chunk(state, chunk, _report) when state.bytes + byte_size(chunk) > state.size,
    do: {:error, {:size_mismatch, state.size, state.bytes + byte_size(chunk)}}

  defp write_chunk(state, chunk, report) do
    case :file.write(state.io, chunk) do
      :ok ->
        bytes = state.bytes + byte_size(chunk)
        hash = :crypto.hash_update(state.hash, chunk)
        {:ok, %{state | hash: hash, bytes: bytes, reported: maybe_report(state, bytes, report)}}

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  defp maybe_report(state, bytes, report) do
    if bytes - state.reported >= @progress_step or bytes == state.size do
      report.(bytes)
      bytes
    else
      state.reported
    end
  end

  defp finish({:ok, %{bytes: bytes, hash: hash}}, part, dest, size, sha256) do
    got = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    result =
      cond do
        bytes != size -> {:error, {:size_mismatch, size, bytes}}
        got != sha256 -> {:error, {:sha256_mismatch, sha256, got}}
        true -> rename(part, dest)
      end

    finish(result, part, dest, size, sha256)
  end

  defp finish({:error, _} = error, part, _dest, _size, _sha256) do
    remove(part)
    error
  end

  defp finish({:done, dest}, _part, _dest, _size, _sha256), do: {:ok, dest}

  defp rename(part, dest) do
    case File.rename(part, dest) do
      :ok -> {:done, dest}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp reporter(opts, total) do
    progress = Keyword.get(opts, :progress)
    notify = Keyword.get(opts, :notify)

    fn bytes ->
      if is_function(progress, 2), do: progress.(bytes, total)
      if is_pid(notify), do: send(notify, {:mob_app_update, {:progress, bytes, total}})
      :ok
    end
  end

  # :dir, else the app's <cacheDir>/mob_app_update (Android), else a temp dir.
  defp dir(opts) do
    case Keyword.fetch(opts, :dir) do
      {:ok, dir} ->
        {:ok, dir}

      :error ->
        case Native.info() do
          {:ok, %{download_dir: dir}} when is_binary(dir) -> {:ok, dir}
          {:error, :unsupported} -> {:ok, Path.join(System.tmp_dir!(), "mob_app_update")}
          {:error, _} = error -> error
        end
    end
  end
end
