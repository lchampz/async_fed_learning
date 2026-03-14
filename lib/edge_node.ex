defmodule AFL.EdgeNode do
  @behaviour :gen_statem
  require Logger

  @max_buffer 5;

  def start_link(id), do: :gen_statem.start_link({:local, __MODULE__}, __MODULE__, id, [])

  @impl true
  @spec init(any()) :: {:ok, :idle, %{buffer: [], id: any()}}
  def init(id) do
    Logger.info("starting edge node #{id}")
    :ets.new(:edge_buffer, [:set, :protected, :named_table])

    {:ok, :connected, %{id: id, buffer: []}}
  end

  @impl true
  def callback_mode, do: :handle_event_function

  defp send_to_aggregator(weights) do
  if :rand.uniform(100) > 10 do
    AFL.Aggregator.update(weights, 100)
    :ok
  else
    {:error, :timeout}
  end
end

  @impl true
  def handle_event(:cast, :train_and_send, :connected, data) do
    weights = MockML.train()

    case send_to_aggregator(weights) do
      :ok -> :keep_state_and_data
      {:error, :timeout} ->
        Logger.error("lost conn, #{self()} is offline")
        new_data = add_to_buffer(weights)

        {:next_state, :disconnected, new_data, [{:state_timeout, 5000, :retry}]}
    end
  end


  @impl true
  def handle_event(:state_timeout, :retry, :disconnected, data) do
    Logger.info("trying reconnection...")

    {:next_state, :connected, data}
  end

  defp add_to_buffer(weights) do
    count = :ets.info(:edge_buffer, :size)

    if count >= @max_buffer do
      Logger.info("not enough space in buffer ets, applying ring buffer...")
      :ets.insert(:edge_buffer, {rem(count, @max_buffer), weights})
    else
      :ets.insert(:edge_buffer, {count, weights})
    end
  end

end
