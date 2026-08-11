defmodule AFL.ModelKeeper do
  @moduledoc """
  Dono permanente e sem lógica de domínio da tabela ETS do estado do
  `AFL.Aggregator` (`:aggregator_state`), com escalonamento para uma
  camada de persistência em disco --- o gap mais crítico deste trabalho
  (o Aggregator é o único ponto de agregação; perdê-lo apaga o modelo
  global inteiro) recebeu a correção mais forte.

  Mesma técnica de posse invertida do `AFL.BufferKeeper` (ver seu
  moduledoc para o argumento estrutural completo de por que encadear
  herdeiros não fecha a janela de corrida do Experimento~R5): este
  processo possui `:aggregator_state` permanentemente, e o
  `AFL.Aggregator` nunca a possui nem a reivindica via
  `:ets.give_away/3` --- apenas lê e escreve nela pelo nome.

  Isso por si só já elimina o cenário original (worker morre, tabela
  sobrevive incondicionalmente). O que a posse invertida sozinha NÃO
  fecha é a morte do próprio dono: se este processo morrer, a tabela ETS
  morre com ele, e uma nova tabela (vazia) seria criada ao reiniciar.
  Fechar esse resíduo por completo exige uma camada de falha
  estruturalmente diferente do processo/ETS --- por isso todo
  `checkpoint/1` também grava, de forma assíncrona, um snapshot em disco
  (escrita atômica: arquivo temporário + `File.rename!/2`, que no POSIX é
  atômico). Ao reiniciar --- inclusive após a queda da BEAM inteira, não
  apenas deste processo --- `init/1` relê esse arquivo e repovoa a tabela
  ETS antes de qualquer `AFL.Aggregator` reivindicá-la, limitando a perda
  máxima a, no pior caso, a última rodada ainda não persistida (não o
  modelo inteiro).
  """
  use GenServer
  require Logger

  @table :aggregator_state
  @checkpoint_dir "ckpt"
  @checkpoint_file Path.join(@checkpoint_dir, "model.bin")
  @checkpoint_tmp Path.join(@checkpoint_dir, "model.tmp")

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def table, do: @table

  @doc """
  Chamado pelo Aggregator ao iniciar: lê o snapshot mais recente
  diretamente da tabela ETS (já repovoada a partir do disco em `init/1`,
  se este processo reiniciou) ou usa `initial_state` no primeiro boot.
  """
  def recover(initial_state) do
    case :ets.lookup(@table, :current) do
      [{:current, state}] -> state
      [] -> initial_state
    end
  end

  @doc """
  Chamado pelo Aggregator a cada mudança de estado: grava na tabela ETS
  (caminho rápido, síncrono) e agenda a persistência em disco
  (assíncrona --- não bloqueia o Aggregator no I/O a cada rodada).
  """
  def checkpoint(state) do
    :ets.insert(@table, {:current, state})
    GenServer.cast(__MODULE__, {:persist, state})
  end

  @doc "Remove qualquer checkpoint em disco de uma execução anterior — chamado no boot da aplicação para garantir que cada execução (teste ou experimento) comece de um estado limpo e reprodutível, sem contaminação entre execuções da BEAM."
  def clear_checkpoint! do
    File.rm_rf!(@checkpoint_dir)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    case load_checkpoint() do
      {:ok, state} -> :ets.insert(@table, {:current, state})
      :none -> :ok
    end

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:persist, state}, data) do
    persist_checkpoint(state)
    {:noreply, data}
  end

  defp persist_checkpoint(state) do
    File.mkdir_p!(@checkpoint_dir)
    blob = :erlang.term_to_binary(state)
    File.write!(@checkpoint_tmp, blob, [:sync])
    File.rename!(@checkpoint_tmp, @checkpoint_file)
  rescue
    e -> Logger.error("[ModelKeeper] Falha ao persistir checkpoint em disco: #{inspect(e)}")
  end

  defp load_checkpoint do
    with {:ok, blob} <- File.read(@checkpoint_file),
         {:ok, state} <- safe_binary_to_term(blob) do
      {:ok, state}
    else
      _ -> :none
    end
  end

  defp safe_binary_to_term(blob) do
    {:ok, :erlang.binary_to_term(blob)}
  rescue
    _ -> :none
  end
end
