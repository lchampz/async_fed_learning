defmodule AFL.ModelKeeper do
  @moduledoc """
  Herdeiro (`:heir`) do estado do `AFL.Aggregator` --- mesma técnica de
  `AFL.BufferKeeper`, aplicada ao gap mais crítico descoberto neste
  trabalho: o Aggregator perdia o \textbf{modelo global inteiro} (pesos,
  versão, total de amostras) a cada \textit{crash}, não apenas o processo.
  O supervisor reinicia o processo rapidamente (Seção R2 do artigo), mas
  sem este mecanismo reconstruía sempre a partir dos pesos iniciais
  estáticos passados ao \texttt{child\_spec}, destruindo todo o progresso
  de treinamento acumulado --- um gap estruturalmente mais grave que o do
  EdgeNode, pois o Aggregator é o único ponto de agregação do sistema.
  """
  use GenServer

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Chamado pelo Aggregator ao iniciar: reivindica o snapshot mais recente
  (se uma instância anterior morreu, com o estado no momento do crash) ou
  usa `initial_state` caso não haja nenhum snapshot ainda.
  """
  def claim_state(initial_state) do
    GenServer.call(__MODULE__, {:claim_state, initial_state})
  end

  @doc "Chamado pelo Aggregator a cada mudança de estado, para manter o snapshot atualizado."
  def checkpoint(state) do
    :ets.insert(:aggregator_state, {:current, state})
  end

  @impl true
  def init(:ok), do: {:ok, %{table: nil}}

  @impl true
  def handle_call({:claim_state, initial_state}, {caller_pid, _}, %{table: nil} = data) do
    table =
      :ets.new(:aggregator_state, [:set, :protected, :named_table, {:heir, self(), :orphaned}])

    :ets.insert(table, {:current, initial_state})
    :ets.give_away(table, caller_pid, :claimed)
    {:reply, initial_state, data}
  end

  def handle_call({:claim_state, initial_state}, {caller_pid, _}, %{table: table} = data) do
    recovered_state =
      case :ets.lookup(table, :current) do
        [{:current, state}] -> state
        [] -> initial_state
      end

    :ets.give_away(table, caller_pid, :claimed)
    {:reply, recovered_state, %{data | table: nil}}
  end

  # Disparado automaticamente pela BEAM quando o proprietário atual da
  # tabela (o Aggregator) morre por qualquer motivo --- inclusive :kill.
  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from_pid, :orphaned}, data) do
    {:noreply, %{data | table: table}}
  end
end
