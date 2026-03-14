defmodule AFL.EdgeNode do
  @behaviour :gen_statem
  require Logger

  @max_buffer 5;

  def start_link(id), do: :gen_statem.start_link(__MODULE__, id, name: __MODULE__)

  @impl true
  def init(id) do
    Logger.info("Starting edge node #{id}")
    {:ok, :idle, %{id: id, buffer: []}}
  end

  @impl true
  def callback_mode, do: :handle_event_function

  # --- CENÁRIO 1: Conectado e recebe ordem de treinar ---
  @impl true
  def handle_event(:cast, :train_and_send, :connected, data) do
    weights = MockML.train() # Simula o treinamento

    case send_to_aggregator(weights) do
      :ok -> :keep_state_and_data
      {:error, :timeout} ->
        Logger.error("Conexão perdida! Movendo para modo offline.")
        new_data = add_to_buffer(data, weights)
        {:next_state, :disconnected, new_data, [{:state_timeout, 5000, :retry}]}
    end
  end

  # --- CENÁRIO 2: Offline e tenta reconectar ---
  @impl true
  def handle_event(:state_timeout, :retry, :disconnected, data) do
    Logger.info("Tentando reconectar e limpar buffer...")
    # Lógica de retry com o buffer aqui
    {:next_state, :connected, data}
  end

  # Helper para o Ring Buffer do seu quadro
  defp add_to_buffer(data, weights) do
    new_buffer = [weights | data.buffer] |> Enum.take(@max_buffer_size)
    %{data | buffer: new_buffer}
  end

end
