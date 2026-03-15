defmodule AFL.EdgeNode do
  @behaviour :gen_statem
  require Logger

  @max_buffer 5;

  def start_link(id), do: :gen_statem.start_link({:local, __MODULE__}, __MODULE__, id, [])

  @impl true

  def init(id) do
    Logger.info("starting edge node #{id}")
    :ets.new(:edge_buffer, [:set, :protected, :named_table])

    monitor = Process.monitor(Process.whereis(AFL.Aggregator))

    {:ok, :connected, %{id: id, buffer: [], monitor: monitor}}
  end

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def handle_event(:cast, :train_and_send, :connected, data) do
    weights = MockML.train()

    case AFL.Aggregator.update(weights, 100) do
      :ok -> :keep_state
      {:error, _} -> disconnect(weights, data)
    end
  end

  @impl true
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _r}, :connected, data) do
    Logger.error("aggregator process went down.")
    {:next_state, :disconnected, data, [{:state_timeout, 5000, :retry}]}
  end

  @impl true
  def handle_event(:cast, :train_n_seed, :disconnected, _data) do
    weights = MockML.train()

    add_to_buffer(weights)
    :keep_state
  end

  @impl true
  def handle_event(:state_timeout, :retry, :disconnected, data) do
    Logger.info("trying reconnection...")

    case (Process.whereis(AFL.Aggregator)) do
      nil -> {:keep_state, data, [{:state_timeout, 5000, :retry}]}
      pid ->
        new_ref = Process.monitor(pid)
        Logger.info("reconnected! syncing buffer..")

        #impl send ets buffer to aggregator and clean it

        {:next_state, :connected, %{data | monitor: new_ref}}
    end
  end


  defp add_to_buffer(weights) do
    count = :ets.info(:edge_buffer, :size)
    key = rem(count, @max_buffer)

    if count >= @max_buffer, do: Logger.info("not enough space in buffer ets, applying ring buffer...")

    :ets.insert(:edge_buffer, {key, weights})
  end

  defp disconnect(weights, data) do
    add_to_buffer(weights)
    {:next_state, :disconnected, data, [{:state_timeout, 5000, :retry}]}
  end

   defp send_to_aggregator(weights) do
    if :rand.uniform(100) > 10 do
      case AFL.Aggregator.update(weights, 100) do
        {:noreply, _} -> :ok
      end
    else
      {:error, :timeout}
    end
  end

end
