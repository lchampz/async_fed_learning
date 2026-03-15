defmodule AFL.Aggregator do
  import Nx, only: [add: 2, multiply: 2]
  @type t :: %__MODULE__{
          weights: Nx.Tensor.t(),
          total: integer(),
          updates_count: integer()
        }

  defstruct weights: nil,
            total: 0,
            updates_count: 0

  use GenServer
  require Logger


  @doc """
  state: {
    weights: o tensor com os pesos,
    total: soma de registros acumulados,
    updates_count: numero de atualizacoes aplicadas
  }
  """
  def start_link(state), do: GenServer.start_link(__MODULE__, state, name: __MODULE__)

  @impl true
  def init(weights) do
    {:ok, %__MODULE__{weights: weights, total: 0, updates_count: 0}}
  end

  def update(e_weights, n_k) do
    if Process.whereis(__MODULE__) do
       GenServer.cast(__MODULE__, {:apply_update, e_weights, n_k})
       :ok
    else
       {:error, :not_reached}
    end

  end

  @doc """
  implementacao da formula W_t+1 = Σ (nk / N) * W_k
  """
  @impl true
  def handle_cast({:apply_update, e_weights, n_k}, %__MODULE__{} = state) do
    new_total = state.total + n_k

    alpha = n_k / new_total
    beta = state.total / new_total

    new_weights = state.weights |> multiply(beta) |> add(multiply(e_weights, alpha))

    new_state = %__MODULE__{
      state
      | weights: new_weights,
        total: new_total,
        updates_count: state.updates_count + 1
    }

    Logger.info("state updated! state #{inspect(new_state)}")

    {:noreply, new_state}
  end

  def get_model() do
    GenServer.call(__MODULE__, :model)
  end

  @impl true
  def handle_call(:model, _from, state) do
    {:reply, state.weights, state}
  end
end
