# Validação em rede real (Fase 4) — repete a comparação async vs sync do
# Experimento A, mas entre nós BEAM DISTRIBUÍDOS DE FATO (processos OS
# separados, conectados por rede real via Erlang distribuído), não dentro
# de uma única VM com Process.sleep simulando latência de rede.
#
# Uso:
#   elixir bench.exs aggregator <k_edges> <duration_ms>
#   elixir bench.exs edge <agg_node_name> <latency_ms>
#
# ROLE é o primeiro argumento. Cada edge simula sua própria latência local
# (tempo de treino, não de rede) via Process.sleep; a latência de rede em
# si é real, não simulada — é o tempo de ida-e-volta genuíno entre nós BEAM
# distintos.

defmodule Bench do
  def run_aggregator(k, duration_ms) do
    Process.register(self(), :aggregator)
    IO.puts("[aggregator] pronto, aguardando #{k} edges conectarem...")

    edges = wait_for_edges(k, [])
    IO.puts("[aggregator] #{k} edges conectados: #{inspect(edges)}")

    # --- Fase assíncrona ---
    Enum.each(edges, fn e -> send(e, {:go_async, duration_ms}) end)
    start = System.monotonic_time(:millisecond)
    async_count = collect_async(0, start + duration_ms + 3_000)
    async_elapsed = System.monotonic_time(:millisecond) - start
    async_ups = async_count / async_elapsed * 1000
    IO.puts("[aggregator] ASYNC: #{async_count} updates em #{async_elapsed}ms => #{Float.round(async_ups, 2)} upd/s")

    # --- Fase síncrona (barreira: aguarda TODOS os edges por rodada) ---
    Enum.each(edges, fn e -> send(e, {:go_sync, duration_ms}) end)
    sync_start = System.monotonic_time(:millisecond)
    sync_rounds = sync_round_loop(edges, sync_start + duration_ms, 0)
    sync_elapsed = System.monotonic_time(:millisecond) - sync_start
    sync_ups = sync_rounds * k / sync_elapsed * 1000
    IO.puts("[aggregator] SYNC: #{sync_rounds} rodadas (#{sync_rounds * k} updates) em #{sync_elapsed}ms => #{Float.round(sync_ups, 2)} upd/s")

    speedup = if sync_ups > 0, do: async_ups / sync_ups, else: :infinity
    IO.puts("[aggregator] SPEEDUP (real network): #{inspect(speedup)}")

    result = %{
      k: k,
      duration_ms: duration_ms,
      async_count: async_count,
      async_elapsed_ms: async_elapsed,
      async_updates_per_s: Float.round(async_ups, 2),
      sync_rounds: sync_rounds,
      sync_elapsed_ms: sync_elapsed,
      sync_updates_per_s: Float.round(sync_ups, 2),
      speedup: if(is_float(speedup), do: Float.round(speedup, 2), else: speedup)
    }

    rep = System.get_env("REP", "1")
    dir = System.get_env("BENCH_OUTPUT_DIR", "/tmp")
    path = Path.join(dir, "distributed_bench_result_#{rep}.json")
    File.write!(path, to_json(result))
    IO.puts("[aggregator] resultado escrito em #{path}")

    Enum.each(edges, fn e -> send(e, :stop) end)
    result
  end

  # Encoder JSON minimalista — sem dependências externas (este script roda
  # fora do projeto mix, só com a stdlib do Elixir).
  defp to_json(map) when is_map(map) do
    fields =
      Enum.map(map, fn {k, v} -> "\"#{k}\":#{json_value(v)}" end)
      |> Enum.join(",")

    "{#{fields}}"
  end

  defp json_value(v) when is_atom(v), do: "\"#{v}\""
  defp json_value(v) when is_number(v), do: to_string(v)
  defp json_value(v), do: "\"#{inspect(v)}\""

  defp wait_for_edges(0, acc), do: acc

  defp wait_for_edges(remaining, acc) do
    receive do
      {:hello, pid} ->
        send(pid, :welcome)
        wait_for_edges(remaining - 1, [pid | acc])
    after
      60_000 -> raise "timeout esperando edges conectarem (#{remaining} faltando)"
    end
  end

  defp collect_async(count, deadline_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      count
    else
      receive do
        {:update, _from} -> collect_async(count + 1, deadline_ms)
      after
        remaining -> count
      end
    end
  end

  defp sync_round_loop(edges, deadline, rounds) do
    if System.monotonic_time(:millisecond) >= deadline do
      rounds
    else
      Enum.each(edges, fn e -> send(e, {:round_go, self()}) end)
      Enum.each(edges, fn _ ->
        receive do
          {:round_ack, _from} -> :ok
        after
          10_000 -> raise "timeout aguardando ack de rodada síncrona"
        end
      end)
      sync_round_loop(edges, deadline, rounds + 1)
    end
  end

  def run_edge(agg_node, latency_ms) do
    agg_node_atom = String.to_atom(agg_node)
    connect_with_retry(agg_node_atom, 30)

    agg_pid =
      case :rpc.call(agg_node_atom, Process, :whereis, [:aggregator]) do
        pid when is_pid(pid) -> pid
        other -> raise "não encontrou :aggregator em #{agg_node}: #{inspect(other)}"
      end

    send(agg_pid, {:hello, self()})

    receive do
      :welcome -> IO.puts("[edge] conectado ao aggregator")
    after
      60_000 -> raise "timeout aguardando :welcome do aggregator"
    end

    edge_loop(latency_ms)
  end

  defp connect_with_retry(_node, 0), do: raise("não conseguiu conectar ao node do aggregator")

  defp connect_with_retry(node, attempts) do
    if Node.connect(node) do
      :ok
    else
      Process.sleep(1_000)
      connect_with_retry(node, attempts - 1)
    end
  end

  defp edge_loop(latency_ms) do
    receive do
      {:go_async, duration_ms} ->
        deadline = System.monotonic_time(:millisecond) + duration_ms
        async_send_loop(latency_ms, deadline)
        edge_loop(latency_ms)

      {:go_sync, duration_ms} ->
        deadline = System.monotonic_time(:millisecond) + duration_ms
        sync_send_loop(latency_ms, deadline)
        edge_loop(latency_ms)

      :stop ->
        IO.puts("[edge] recebeu :stop, encerrando")
        :ok
    end
  end

  defp async_send_loop(latency_ms, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(latency_ms)
      send({:aggregator, node_of_aggregator()}, {:update, self()})
      async_send_loop(latency_ms, deadline)
    end
  end

  defp sync_send_loop(latency_ms, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      receive do
        {:round_go, from} ->
          Process.sleep(latency_ms)
          send(from, {:round_ack, self()})
          sync_send_loop(latency_ms, deadline)
      after
        5_000 -> :ok
      end
    else
      # Drena qualquer :round_go pendente para não travar o aggregator
      receive do
        {:round_go, from} -> send(from, {:round_ack, self()})
      after
        0 -> :ok
      end
    end
  end

  defp node_of_aggregator do
    [agg_node | _] = Node.list()
    agg_node
  end
end

[role | args] = System.argv()

case role do
  "aggregator" ->
    [k_str, duration_str] = args
    Bench.run_aggregator(String.to_integer(k_str), String.to_integer(duration_str))

  "edge" ->
    [agg_node, latency_str] = args
    Bench.run_edge(agg_node, String.to_integer(latency_str))
end
