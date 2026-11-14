defmodule MobAppUpdate.TestServer do
  @moduledoc false
  # A minimal HTTP/1.1 server on 127.0.0.1 for the host tests: one request per
  # connection, served in order. Routes map a request path (with query) to
  # `{status, headers, body}`. Every request is reported to the starting
  # process as `{:test_server, path, headers}`.

  @type t :: %{url: String.t(), routes: pid()}

  @spec start() :: t()
  def start do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    {:ok, routes} = Agent.start_link(fn -> %{} end)
    parent = self()
    acceptor = spawn_link(fn -> accept(listen, routes, parent) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)
    %{url: "http://127.0.0.1:#{port}", routes: routes}
  end

  @spec route(t(), String.t(), {pos_integer(), [{String.t(), String.t()}], iodata()}) :: :ok
  def route(server, path, response), do: Agent.update(server.routes, &Map.put(&1, path, response))

  @spec redirect(t(), String.t(), String.t()) :: :ok
  def redirect(server, path, location),
    do: route(server, path, {302, [{"location", location}], ""})

  defp accept(listen, routes, parent) do
    {:ok, socket} = :gen_tcp.accept(listen)
    serve(socket, routes, parent)
    accept(listen, routes, parent)
  end

  defp serve(socket, routes, parent) do
    with {:ok, {:http_request, _method, {:abs_path, path}, _version}} <- :gen_tcp.recv(socket, 0),
         {:ok, headers} <- read_headers(socket, []) do
      send(parent, {:test_server, path, headers})

      {status, extra, body} =
        Agent.get(routes, &Map.get(&1, path, {404, [], ~s({"message":"Not Found"})}))

      head =
        [
          "HTTP/1.1 #{status} X\r\n",
          "content-length: #{IO.iodata_length(body)}\r\n",
          "connection: close\r\n"
        ] ++
          Enum.map(extra, fn {key, value} -> "#{key}: #{value}\r\n" end)

      :gen_tcp.send(socket, [head, "\r\n", body])
    end

    :gen_tcp.close(socket)
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, [{header_name(name), value} | acc])

      {:ok, :http_eoh} ->
        {:ok, Map.new(acc)}

      other ->
        other
    end
  end

  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(name), do: String.downcase(name)
end
