defmodule AFL.BufferKeeper do
  @moduledoc """
  Herdeiro (`:heir`) fixo do ring buffer ETS do EdgeNode.

  Gap de resiliência descoberto empiricamente (Experimento H): por padrão,
  uma tabela ETS morre com o processo que a criou. O `EdgeNode` criava sua
  própria tabela `:edge_buffer` sem herdeiro — se o próprio EdgeNode
  falhasse (não o Aggregator), a tabela e todos os gradientes bufferizados
  eram destruídos junto, mesmo que algo o reiniciasse depois: a nova
  instância simplesmente criava uma tabela vazia.

  Este processo vive na árvore de supervisão estática da aplicação (nunca
  reinicia junto com o EdgeNode) e herda a tabela via `:heir` sempre que o
  proprietário atual morre, devolvendo-a para a próxima instância que a
  reivindicar via `claim_buffer/0` — preservando o conteúdo através de
  crashes.
  """
  use GenServer

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Chamado pelo EdgeNode ao iniciar: reivindica a tabela órfã de uma
  instância anterior (se existir, com seu conteúdo intacto) ou cria uma
  nova, já com este processo como herdeiro.
  """
  def claim_buffer do
    GenServer.call(__MODULE__, :claim_buffer)
  end

  @impl true
  def init(:ok), do: {:ok, %{table: nil}}

  @impl true
  def handle_call(:claim_buffer, {caller_pid, _}, %{table: nil} = state) do
    table =
      :ets.new(:edge_buffer, [:set, :protected, :named_table, {:heir, self(), :orphaned}])

    :ets.give_away(table, caller_pid, :claimed)
    {:reply, table, state}
  end

  def handle_call(:claim_buffer, {caller_pid, _}, %{table: table} = state) do
    :ets.give_away(table, caller_pid, :claimed)
    {:reply, table, %{state | table: nil}}
  end

  # Disparado automaticamente pela BEAM quando o proprietário atual da
  # tabela (o EdgeNode) morre por qualquer motivo — inclusive :kill.
  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from_pid, :orphaned}, state) do
    {:noreply, %{state | table: table}}
  end
end
