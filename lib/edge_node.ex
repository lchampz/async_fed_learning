defmodule AFL.EdgeNode do
  @behaviour :gen_statem
  require Logger

  # Hard cap on locally buffered updates. Oldest entry is overwritten when full.
  @max_buffer 5

  def start_link(id),
    do: :gen_statem.start_link({:local, __MODULE__}, __MODULE__, id, [])

  @impl true
  def init(id) do
    Logger.info("[EdgeNode #{id}] Starting")
    # A tabela :edge_buffer pertence permanentemente ao AFL.BufferKeeper
    # (posse invertida — ver moduledoc) — este processo nunca a possui,
    # nunca a cria e nunca a reivindica; apenas escreve nela pelo nome.
    # Se esta instância morreu antes (crash), o conteúdo bufferizado
    # continua lá, intacto, sem nenhum handoff necessário.

    {state, monitor_ref, actions} =
      case Process.whereis(AFL.Aggregator) do
        nil ->
          Logger.warning("[EdgeNode #{id}] Aggregator not found — starting disconnected")
          {:disconnected, nil, [{:state_timeout, 5000, :retry}]}

        pid ->
          {:connected, Process.monitor(pid), []}
      end

    data = %{
      id: id,
      monitor_ref: monitor_ref,
      # total writes ever (not ETS size) — drives the circular key calculation
      buffer_count: 0,
      # aggregator version at the moment this node last went offline
      last_synced_version: 0
    }

    {:ok, state, data, actions}
  end

  @impl true
  def callback_mode, do: :handle_event_function

  # ---- CONNECTED ----

  @impl true
  def handle_event(:cast, :train_and_send, :connected, data) do
    weights = MockML.train()

    case AFL.Aggregator.update(weights, 100) do
      :ok -> :keep_state_and_data
      {:error, _} -> go_offline(weights, data)
    end
  end

  # Aggregator process went down — captured via Process.monitor
  @impl true
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, :connected, data) do
    Logger.error("[EdgeNode #{data.id}] Aggregator went down → :disconnected")

    # Capture version best-effort (aggregator may already be gone)
    last_version =
      try do
        AFL.Aggregator.get_version()
      catch
        _, _ -> data.last_synced_version
      end

    new_data = %{data | monitor_ref: nil, last_synced_version: last_version}
    {:next_state, :disconnected, new_data, [{:state_timeout, 5000, :retry}]}
  end

  # ---- DISCONNECTED ----

  @impl true
  def handle_event(:cast, :train_and_send, :disconnected, data) do
    weights = MockML.train()
    new_count = write_to_ring_buffer(weights, data.last_synced_version, data.buffer_count)
    {:keep_state, %{data | buffer_count: new_count}}
  end

  # Stale :DOWN signal arriving after we already transitioned — discard
  @impl true
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, :disconnected, _data) do
    :keep_state_and_data
  end

  # Reconnection retry loop (exponential backoff can be added by scaling the timeout)
  @impl true
  def handle_event(:state_timeout, :retry, :disconnected, data) do
    Logger.info("[EdgeNode #{data.id}] Attempting reconnection…")

    case Process.whereis(AFL.Aggregator) do
      nil ->
        {:keep_state, data, [{:state_timeout, 5000, :retry}]}

      pid ->
        new_ref = Process.monitor(pid)
        Logger.info("[EdgeNode #{data.id}] Reconnected — flushing buffer")
        flush_buffer()
        current_version = AFL.Aggregator.get_version()

        new_data = %{
          data
          | monitor_ref: new_ref,
            buffer_count: 0,
            last_synced_version: current_version
        }

        {:next_state, :connected, new_data}
    end
  end

  # Chamado em parada ORDENADA (:gen_statem.stop/1, supervisor shutdown) —
  # NÃO é chamado em :kill (sinal não-capturável, pula terminate/3). Essa
  # assimetria é exatamente o que queremos: uma parada deliberada limpa o
  # buffer (próxima instância começa do zero); um crash preserva o
  # conteúdo para o herdeiro devolver depois.
  @impl true
  def terminate(_reason, _state, _data) do
    :ets.delete_all_objects(:edge_buffer)
    :ok
  end

  # ---- Private helpers ----

  defp go_offline(weights, data) do
    new_count = write_to_ring_buffer(weights, data.last_synced_version, data.buffer_count)
    new_data = %{data | monitor_ref: nil, buffer_count: new_count}
    {:next_state, :disconnected, new_data, [{:state_timeout, 5000, :retry}]}
  end

  # Uses `total_count` (not ETS size) as the ring pointer so the circular
  # behaviour works correctly when the table is full and entries are overwritten.
  defp write_to_ring_buffer(weights, edge_version, total_count) do
    key = rem(total_count, @max_buffer)

    if total_count >= @max_buffer do
      Logger.warning("[EdgeNode] Buffer full (NES) — overwriting index #{key}")
    end

    :ets.insert(:edge_buffer, {key, weights, edge_version})
    total_count + 1
  end

  defp flush_buffer do
    updates = :ets.tab2list(:edge_buffer)

    Enum.each(updates, fn {_key, weights, edge_version} ->
      AFL.Aggregator.update(weights, 100, edge_version)
    end)

    :ets.delete_all_objects(:edge_buffer)
    Logger.info("[EdgeNode] Flushed #{length(updates)} buffered update(s)")
  end
end
