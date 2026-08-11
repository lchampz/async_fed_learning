defmodule AFL.Aggregator do
  require Logger

  @type t :: %__MODULE__{
          weights: Nx.Tensor.t(),
          total: float(),
          updates_count: integer(),
          version: integer()
        }

  defstruct weights: nil,
            total: 0.0,
            updates_count: 0,
            version: 0

  use GenServer

  def start_link(initial_weights),
    do: GenServer.start_link(__MODULE__, initial_weights, name: __MODULE__)

  @impl true
  def init(initial_weights) do
    # A tabela :aggregator_state pertence permanentemente ao
    # AFL.ModelKeeper (posse invertida — ver seu moduledoc); este processo
    # nunca a possui. Recupera o snapshot mais recente em vez de sempre
    # partir de `initial_weights` incondicionalmente — se uma instância
    # anterior deste Aggregator morreu, o progresso de treinamento (pesos,
    # versão, total de amostras) sobrevive e é devolvido aqui.
    state = AFL.ModelKeeper.recover(%__MODULE__{weights: initial_weights})
    {:ok, state}
  end

  @doc """
  Dispatches an async FedAvg update to the aggregator.

  `edge_version` is the aggregator version the edge node last saw. Omit (or pass
  nil) for fresh updates. Stale updates are penalized proportionally to the gap:
  effective_n_k = n_k * (1 / (1 + staleness_gap))
  """
  def update(e_weights, n_k, edge_version \\ nil) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:apply_update, e_weights, n_k, edge_version})
      :ok
    else
      {:error, :not_reached}
    end
  end

  def get_model, do: GenServer.call(__MODULE__, :model)
  def get_version, do: GenServer.call(__MODULE__, :version)
  def get_state, do: GenServer.call(__MODULE__, :full_state)

  def reset(initial_weights),
    do: GenServer.call(__MODULE__, {:reset, initial_weights})

  @doc """
  Restaura o estado completo (pesos, total de amostras e versão) — usado
  pelos experimentos para reproduzir um ponto de referência exato ("modelo
  fresco") a partir do qual múltiplas trajetórias de staleness são simuladas.
  """
  def restore(%{weights: _, total: _, version: _} = snapshot),
    do: GenServer.call(__MODULE__, {:restore, snapshot})

  @doc """
  Combinação FedAvg pura (sem efeito colateral) — expõe a mesma matemática
  usada internamente pelo GenServer para permitir contrafactuais: "o que
  aconteceria se este update, com este fator de staleness, fosse aplicado
  a este snapshot?" sem mutar o processo real.
  """
  def fedavg_merge(weights, total, e_weights, effective_n_k) do
    new_total = total + effective_n_k
    alpha = effective_n_k / new_total
    beta = total / new_total
    {weighted_combine(weights, e_weights, beta, alpha), new_total}
  end

  @doc """
  Combinação convexa pura $\\beta \\cdot a + \\alpha \\cdot b$, aplicada
  recursivamente sobre a mesma estrutura de parâmetros (tensor único ou
  Axon.ModelState). Exposta publicamente para uso por baselines de
  comparação (Seção `AFL.Baselines`) que usam regras de mistura diferentes
  do FedAvg incremental do AFL — ex.: mistura de peso fixo do FedAsync.
  """
  def convex_combine(a, b, beta, alpha), do: weighted_combine(a, b, beta, alpha)

  # --- Callbacks ---

  @impl true
  def handle_cast({:apply_update, e_weights, n_k, edge_version}, %__MODULE__{} = state) do
    staleness_gap =
      case edge_version do
        nil -> 0
        v -> max(0, state.version - v)
      end

    # Penalize stale gradients: effective contribution decays with version gap
    staleness_factor = 1.0 / (1 + staleness_gap)
    effective_n_k = n_k * staleness_factor

    new_total = state.total + effective_n_k
    alpha = effective_n_k / new_total
    beta = state.total / new_total

    new_weights = weighted_combine(state.weights, e_weights, beta, alpha)

    new_state = %__MODULE__{
      state
      | weights: new_weights,
        total: new_total,
        updates_count: state.updates_count + 1,
        version: state.version + 1
    }

    if staleness_gap > 0 do
      Logger.warning(
        "[Aggregator] Stale update applied: gap=#{staleness_gap}, " <>
          "staleness_factor=#{Float.round(staleness_factor, 3)}"
      )
    end

    Logger.info(
      "[Aggregator] v#{new_state.version} | updates=#{new_state.updates_count} | " <>
        "total_samples=#{Float.round(new_state.total, 1)}"
    )

    AFL.ModelKeeper.checkpoint(new_state)
    {:noreply, new_state}
  end

  # Variante síncrona (blocking) — usada nos experimentos Sync vs Async
  def update_sync(e_weights, n_k, edge_version \\ nil) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:apply_update, e_weights, n_k, edge_version})
    else
      {:error, :not_reached}
    end
  end

  @impl true
  def handle_call(:model, _from, state), do: {:reply, state.weights, state}

  @impl true
  def handle_call(:version, _from, state), do: {:reply, state.version, state}

  @impl true
  def handle_call(:full_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:reset, initial_weights}, _from, _state) do
    new_state = %__MODULE__{weights: initial_weights}
    AFL.ModelKeeper.checkpoint(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:restore, snapshot}, _from, _state) do
    new_state = %__MODULE__{
      weights: snapshot.weights,
      total: snapshot.total,
      version: snapshot.version,
      updates_count: 0
    }

    AFL.ModelKeeper.checkpoint(new_state)
    {:reply, :ok, new_state}
  end

  # Variante call do apply_update — mesma lógica do cast, mas retorna :ok
  @impl true
  def handle_call({:apply_update, e_weights, n_k, edge_version}, _from, state) do
    {:noreply, new_state} = handle_cast({:apply_update, e_weights, n_k, edge_version}, state)
    {:reply, :ok, new_state}
  end

  # ---- FedAvg incremental genérico ----
  #
  # Suporta tanto um Nx.Tensor único (usado nos testes com MockML) quanto
  # um Axon.ModelState / mapa aninhado de tensores por camada (usado pelo
  # AFL.Model real) — combinação convexa aplicada recursivamente sobre a
  # mesma estrutura.
  defp weighted_combine(%Axon.ModelState{} = old, %Axon.ModelState{} = new, beta, alpha) do
    %{old | data: weighted_combine(old.data, new.data, beta, alpha)}
  end

  defp weighted_combine(%Nx.Tensor{} = old, %Nx.Tensor{} = new, beta, alpha) do
    old |> Nx.multiply(beta) |> Nx.add(Nx.multiply(new, alpha))
  end

  defp weighted_combine(old, new, beta, alpha) when is_map(old) and is_map(new) do
    Map.new(old, fn {k, v} -> {k, weighted_combine(v, Map.fetch!(new, k), beta, alpha)} end)
  end
end
