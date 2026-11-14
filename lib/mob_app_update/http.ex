defmodule MobAppUpdate.HTTP do
  @moduledoc false
  # HTTP(S) over OTP's :httpc + :ssl (both in a Mob release; no Req). Redirects
  # are followed here, not by httpc, so each hop gets TLS options for its own
  # host (GitHub's asset links 302 to another host). Android has no CA store
  # where :public_key looks, so the trust store falls back to the system's
  # /system/etc/security/cacerts (one PEM per authority).
  #
  # Options (every MobAppUpdate call that reaches the network takes them):
  #   :cacerts         — trusted CAs (DER or :public_key.cacerts_get/0 form);
  #                      default: OS store, else Android's system store
  #   :ssl             — extra :ssl client options, appended
  #   :user_agent      — default "mob_app_update"
  #   :timeout         — ms; a whole small request, or the silence allowed
  #                      between chunks of a download (default 60_000)
  #   :connect_timeout — ms (default 15_000)

  @android_cacerts "/system/etc/security/cacerts"
  @max_redirects 5
  @default_timeout 60_000
  @default_connect_timeout 15_000

  @type opts :: keyword()

  @doc false
  # GET into memory; refuses bodies over `max_bytes`.
  @spec get(String.t(), [{String.t(), String.t()}], opts(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def get(url, headers, opts, max_bytes) do
    with :ok <- start() do
      get(url, headers, opts, max_bytes, @max_redirects)
    end
  end

  defp get(_url, _headers, _opts, _max, -1), do: {:error, :too_many_redirects}

  defp get(url, headers, opts, max_bytes, redirects) do
    with {:ok, http_opts} <- http_opts(url, opts, Keyword.get(opts, :timeout, @default_timeout)) do
      request = {to_charlist(url), request_headers(headers, opts)}

      case :httpc.request(:get, request, http_opts, body_format: :binary) do
        {:ok, {{_, 200, _}, _headers, body}} when byte_size(body) <= max_bytes ->
          {:ok, body}

        {:ok, {{_, 200, _}, _headers, body}} ->
          {:error, {:too_large, byte_size(body)}}

        {:ok, {{_, status, _}, resp_headers, _body}} ->
          case redirect(url, status, resp_headers) do
            {:ok, next} -> get(next, headers, opts, max_bytes, redirects - 1)
            :none -> {:error, status_error(status, resp_headers)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # Streaming GET with flow control ({:self, :once}). `handler` gets
  # `{:data, chunk}` and returns `{:ok, state}` or `{:error, reason}`, which
  # cancels the request.
  @spec stream(String.t(), opts(), state, ({:data, binary()}, state ->
                                             {:ok, state} | {:error, term()})) ::
          {:ok, state} | {:error, term()}
        when state: term()
  def stream(url, opts, state, handler) do
    with :ok <- start() do
      stream(url, opts, state, handler, @max_redirects)
    end
  end

  defp stream(_url, _opts, _state, _handler, -1), do: {:error, :too_many_redirects}

  defp stream(url, opts, state, handler, redirects) do
    with {:ok, http_opts} <- http_opts(url, opts, :infinity),
         {:ok, ref} <-
           :httpc.request(
             :get,
             {to_charlist(url), request_headers([], opts)},
             http_opts,
             sync: false,
             stream: {:self, :once},
             body_format: :binary
           ) do
      case receive_stream(ref, nil, state, handler, Keyword.get(opts, :timeout, @default_timeout)) do
        {:response, status, headers} ->
          case redirect(url, status, headers) do
            {:ok, next} -> stream(next, opts, state, handler, redirects - 1)
            :none -> {:error, status_error(status, headers)}
          end

        other ->
          other
      end
    end
  end

  defp receive_stream(ref, pid, state, handler, timeout) do
    receive do
      {:http, {^ref, :stream_start, _headers, stream_pid}} ->
        :ok = :httpc.stream_next(stream_pid)
        receive_stream(ref, stream_pid, state, handler, timeout)

      {:http, {^ref, :stream, chunk}} ->
        case handler.({:data, chunk}, state) do
          {:ok, state} ->
            :ok = :httpc.stream_next(pid)
            receive_stream(ref, pid, state, handler, timeout)

          {:error, _} = error ->
            :httpc.cancel_request(ref)
            error
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, state}

      {:http, {^ref, {{_, status, _}, headers, _body}}} ->
        {:response, status, headers}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      timeout ->
        :httpc.cancel_request(ref)
        {:error, :timeout}
    end
  end

  defp redirect(url, status, headers) when status in [301, 302, 303, 307, 308] do
    case header(headers, "location") do
      nil -> :none
      location -> {:ok, url |> URI.merge(location) |> URI.to_string()}
    end
  end

  defp redirect(_url, _status, _headers), do: :none

  defp status_error(404, _headers), do: :not_found

  defp status_error(status, headers) when status in [403, 429] do
    if header(headers, "x-ratelimit-remaining") == "0" do
      {:rate_limited, rate_limit_reset(header(headers, "x-ratelimit-reset"))}
    else
      {:http_status, status}
    end
  end

  defp status_error(status, _headers), do: {:http_status, status}

  defp rate_limit_reset(nil), do: nil

  defp rate_limit_reset(value) do
    case Integer.parse(value) do
      {unix, ""} -> DateTime.from_unix!(unix)
      _ -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp request_headers(headers, opts) do
    agent = Keyword.get(opts, :user_agent, "mob_app_update")

    for {key, value} <- [{"user-agent", agent} | headers],
        do: {to_charlist(key), to_charlist(value)}
  end

  defp http_opts(url, opts, timeout) do
    base = [
      autoredirect: false,
      timeout: timeout,
      connect_timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    ]

    case URI.parse(url).scheme do
      "https" ->
        with {:ok, ssl} <- ssl_opts(opts), do: {:ok, [{:ssl, ssl} | base]}

      # httpc's default for an absent :ssl option calls
      # :public_key.cacerts_get/0, which raises on Android even for http://.
      "http" ->
        {:ok, [{:ssl, []} | base]}

      _ ->
        {:error, {:bad_url, url}}
    end
  end

  defp ssl_opts(opts) do
    case Keyword.get_lazy(opts, :cacerts, &default_cacerts/0) do
      [] ->
        {:error, :no_ca_certificates}

      cacerts ->
        {:ok,
         [
           verify: :verify_peer,
           cacerts: cacerts,
           customize_hostname_check: [
             match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
           ]
         ] ++ Keyword.get(opts, :ssl, [])}
    end
  end

  defp default_cacerts do
    case :persistent_term.get({__MODULE__, :cacerts}, nil) do
      nil ->
        certs = load_cacerts()
        if certs != [], do: :persistent_term.put({__MODULE__, :cacerts}, certs)
        certs

      certs ->
        certs
    end
  end

  defp load_cacerts do
    case os_cacerts() do
      [] -> android_cacerts()
      certs -> certs
    end
  end

  defp os_cacerts do
    :public_key.cacerts_get()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp android_cacerts do
    case File.ls(@android_cacerts) do
      {:ok, files} ->
        for file <- files,
            {:ok, pem} <- [File.read(Path.join(@android_cacerts, file))],
            {:Certificate, der, _} <- :public_key.pem_decode(pem),
            do: der

      {:error, _} ->
        []
    end
  end

  # (a release without :inets or :ssl answers {:error, ...} here rather than
  # crashing the caller)
  defp start do
    case Application.ensure_all_started([:ssl, :inets]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:not_started, reason}}
    end
  end
end
