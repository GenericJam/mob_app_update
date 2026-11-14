defmodule MobAppUpdate.HTTP do
  @moduledoc false
  # HTTPS over OTP's :httpc + :ssl (both in a Mob release; no Req). Redirects
  # are followed here, not by httpc, so each hop gets TLS options for its own
  # host (GitHub's asset links 302 to another host) and each hop must be
  # https: a redirect can't downgrade to plaintext. Android has no CA store
  # where :public_key looks, so the trust store falls back to the system's
  # /system/etc/security/cacerts (one PEM per authority).
  #
  # Options (every MobAppUpdate call that reaches the network takes them):
  #   :cacerts         — trusted CAs (DER or :public_key.cacerts_get/0 form);
  #                      default: OS store, else Android's system store
  #   :ssl             — extra :ssl client options, appended
  #   :user_agent      — default "mob_app_update"
  #   :timeout         — ms of silence allowed while waiting for the response
  #                      or between chunks of its body (default 60_000)
  #   :connect_timeout — ms (default 15_000)
  #   :allow_loopback_http — also accept http:// to 127.0.0.1 / ::1 /
  #                      localhost (tests, adb reverse); default false. Any
  #                      other http:// URL or hop is {:insecure_url, url}.

  @android_cacerts "/system/etc/security/cacerts"
  @max_redirects 5
  @default_timeout 60_000
  @default_connect_timeout 15_000
  @loopback_hosts ["127.0.0.1", "::1", "localhost"]

  @type opts :: keyword()

  @doc false
  # GET into memory; refuses (and stops reading) a body over `max_bytes`.
  @spec get(String.t(), [{String.t(), String.t()}], opts(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def get(url, headers, opts, max_bytes) do
    collect = fn {:data, chunk}, {size, acc} ->
      size = size + byte_size(chunk)
      if size > max_bytes, do: {:error, {:too_large, size}}, else: {:ok, {size, [acc | chunk]}}
    end

    with {:ok, {_size, body}} <- request(url, headers, opts, {0, []}, collect) do
      {:ok, IO.iodata_to_binary(body)}
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
  def stream(url, opts, state, handler), do: request(url, [], opts, state, handler)

  defp request(url, headers, opts, state, handler) do
    with :ok <- start() do
      request(url, headers, opts, state, handler, @max_redirects)
    end
  end

  defp request(_url, _headers, _opts, _state, _handler, -1), do: {:error, :too_many_redirects}

  defp request(url, headers, opts, state, handler, redirects) do
    with {:ok, http_opts} <- http_opts(url, opts),
         {:ok, ref} <-
           :httpc.request(
             :get,
             {to_charlist(url), request_headers(headers, opts)},
             http_opts,
             sync: false,
             stream: {:self, :once},
             body_format: :binary
           ) do
      case receive_stream(ref, nil, state, handler, Keyword.get(opts, :timeout, @default_timeout)) do
        {:response, status, resp_headers} ->
          case redirect(url, status, resp_headers) do
            {:ok, next} -> request(next, headers, opts, state, handler, redirects - 1)
            :none -> {:error, status_error(status, resp_headers)}
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
            cancel(ref)
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
        cancel(ref)
        {:error, :timeout}
    end
  end

  # Downloads run in the caller's process: leave nothing of a cancelled
  # request in its mailbox.
  defp cancel(ref) do
    :httpc.cancel_request(ref)
    flush(ref)
  end

  defp flush(ref) do
    receive do
      {:http, {^ref, _}} -> flush(ref)
      {:http, {^ref, _, _}} -> flush(ref)
      {:http, {^ref, _, _, _}} -> flush(ref)
    after
      0 -> :ok
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
    with {unix, ""} <- Integer.parse(value),
         {:ok, time} <- DateTime.from_unix(unix) do
      time
    else
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

  # The request has no overall deadline (a 100 MB download takes as long as
  # it takes); receive_stream/5 enforces :timeout between messages.
  defp http_opts(url, opts) when is_binary(url) do
    base = [
      autoredirect: false,
      timeout: :infinity,
      connect_timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    ]

    uri = URI.parse(url)

    case uri.scheme do
      "https" ->
        with {:ok, ssl} <- ssl_opts(opts), do: {:ok, [{:ssl, ssl} | base]}

      # httpc's default for an absent :ssl option calls
      # :public_key.cacerts_get/0, which raises on Android even for http://.
      "http" ->
        if Keyword.get(opts, :allow_loopback_http) == true and uri.host in @loopback_hosts,
          do: {:ok, [{:ssl, []} | base]},
          else: {:error, {:insecure_url, url}}

      _ ->
        {:error, {:bad_url, url}}
    end
  end

  defp http_opts(url, _opts), do: {:error, {:bad_url, url}}

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
