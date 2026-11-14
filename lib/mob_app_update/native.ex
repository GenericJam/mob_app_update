defmodule MobAppUpdate.Native do
  @moduledoc false
  # The NIF seam (Android: priv/native/jni/mob_app_update_nif.zig ->
  # MobAppUpdateBridge.kt). Off Android every call answers
  # {:error, :unsupported} without touching the NIF. The bridge answers JSON;
  # this module decodes it into atom-keyed maps.

  @typedoc "A package as PackageManager describes it (installed app or APK file)."
  @type package_info :: %{
          package: String.t(),
          version_code: pos_integer(),
          version_name: String.t(),
          signers: [String.t()],
          signer_history: [String.t()],
          multiple_signers: boolean()
        }

  @spec android?() :: boolean()
  def android?, do: platform() == :android

  # :host when mob's NIF isn't loaded (dev, tests). Asked once per VM.
  @spec platform() :: atom()
  def platform do
    case :persistent_term.get({__MODULE__, :platform}, nil) do
      nil ->
        platform = ask_platform()
        :persistent_term.put({__MODULE__, :platform}, platform)
        platform

      platform ->
        platform
    end
  end

  defp ask_platform do
    :mob_nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
  end

  @doc false
  # The installed app plus `download_dir` (<cacheDir>/mob_app_update).
  @spec info() :: {:ok, package_info() | map()} | {:error, term()}
  def info do
    with :ok <- require_android(),
         {:ok, json} <- :mob_app_update_nif.app_update_info(),
         {:ok, map} <- decode(json) do
      {:ok, map |> package_info() |> Map.put(:download_dir, map["download_dir"])}
    end
  end

  @spec can_request_installs?() :: boolean()
  def can_request_installs? do
    android?() and :mob_app_update_nif.app_update_can_request_installs() == true
  end

  @spec open_install_settings() :: :ok | {:error, term()}
  def open_install_settings do
    with :ok <- require_android() do
      :mob_app_update_nif.app_update_open_install_settings()
    end
  end

  @spec inspect_apk(Path.t()) :: {:ok, package_info()} | {:error, term()}
  def inspect_apk(path) do
    with :ok <- require_android(),
         {:ok, json} <- :mob_app_update_nif.app_update_inspect(path),
         {:ok, map} <- decode(json) do
      case map do
        %{"error" => "invalid_apk"} -> {:error, :invalid_apk}
        map -> {:ok, package_info(map)}
      end
    end
  end

  @spec install(Path.t(), pid()) :: :ok | {:error, term()}
  def install(path, pid) do
    with :ok <- require_android() do
      :mob_app_update_nif.app_update_install(path, pid)
    end
  end

  # Bytes available to this app on the file system holding `dir`
  # (File.getUsableSpace).
  @spec free_space(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def free_space(dir) do
    with :ok <- require_android(),
         {:ok, json} <- :mob_app_update_nif.app_update_free_space(dir),
         {:ok, map} <- decode(json) do
      case map do
        %{"free_bytes" => free} when is_integer(free) and free >= 0 -> {:ok, free}
        _ -> {:error, {:bad_bridge_reply, json}}
      end
    end
  end

  defp require_android, do: if(android?(), do: :ok, else: {:error, :unsupported})

  # The bridge answers {"error": "unsupported_sdk"} below API 28 (the
  # manifest's min_sdk), where the SigningInfo APIs it uses don't exist.
  defp decode(json) do
    case JSON.decode(json) do
      {:ok, %{"error" => "unsupported_sdk"}} -> {:error, :unsupported}
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, {:bad_bridge_reply, json}}
    end
  end

  @doc false
  @spec package_info(map()) :: package_info()
  def package_info(map) do
    %{
      package: map["package"],
      version_code: map["version_code"],
      version_name: map["version_name"] || "",
      signers: map["signers"] || [],
      signer_history: map["signer_history"] || [],
      multiple_signers: map["multiple_signers"] == true
    }
  end
end
