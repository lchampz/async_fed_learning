defmodule AFL.BufferKeeper do
  @moduledoc """
  Dono permanente e sem lógica de domínio da tabela ETS do ring buffer do
  EdgeNode (`:edge_buffer`).

  Gap original (Experimento R1, corrigido numa primeira versão via
  `:heir`) e gap residual (Experimento R5): o padrão de herdeiro vincula o
  `:heir` a um `pid` no momento da criação da tabela, e esse vínculo nunca
  é atualizado se o próprio herdeiro reinicia --- se o herdeiro morre
  antes do dono, a tabela morre com o dono sem ninguém para recebê-la
  (100% de perda, ver `sec:r5` no artigo). Encadear um segundo herdeiro
  não fecha essa janela: ela só se desloca um nível, pela mesma
  coincidência de timing.

  A correção estrutural é não ter herdeiro: a tabela nunca pertence ao
  EdgeNode. Este processo a possui permanentemente e nunca a repassa via
  `:ets.give_away/3` --- ele não tem nenhuma lógica de domínio (nenhuma
  agregação, nenhum tratamento de gradiente), então sua própria
  superfície de crash é próxima de zero. O `AFL.EdgeNode` escreve direto
  na tabela nomeada e pública; seu crash nunca toca a tabela, porque ele
  nunca foi o proprietário.

  Isso não elimina todo risco: se este processo morrer (finalização pelo
  supervisor, `Process.exit/2` externo, queda da BEAM), a tabela morre
  com ele --- mas esse é um cenário raro e determinístico (a árvore de
  supervisão usa `:rest_for_one`, então o EdgeNode reinicia junto, de
  forma consistente), não uma janela de corrida silenciosa e sem limite
  de tempo. Fechar esse resíduo por completo exige escalar para uma
  camada de persistência (disco), não mais processos ETS --- ver
  `AFL.ModelKeeper` para essa escalada aplicada ao estado mais crítico do
  sistema (o modelo global).
  """
  use GenServer

  @table :edge_buffer

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def table, do: @table

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
