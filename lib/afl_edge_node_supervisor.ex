defmodule AFL.EdgeNodeSupervisor do
  @moduledoc """
  Supervisor dinâmico para `AFL.EdgeNode` — descoberto como ausente
  (Experimento H): a aplicação supervisionava apenas o `AFL.Aggregator`;
  um `EdgeNode` morto nunca era reiniciado por ninguém. Nós iniciados aqui
  são reiniciados automaticamente (`:permanent`, estratégia `:one_for_one`)
  em caso de crash, combinado com `AFL.BufferKeeper` para preservar o ring
  buffer através do restart.
  """
  use DynamicSupervisor

  def start_link(init_arg), do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg),
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1000, max_seconds: 10)

  @doc "Inicia um EdgeNode supervisionado — reiniciado automaticamente em caso de crash."
  def start_edge_node(id) do
    # AFL.EdgeNode usa @behaviour :gen_statem diretamente (não `use GenServer`),
    # então não ganha child_spec/1 automático — especifica-se o spec explícito.
    child_spec = %{
      id: {AFL.EdgeNode, id},
      start: {AFL.EdgeNode, :start_link, [id]},
      restart: :permanent
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Para o EdgeNode supervisionado atual (parada ordenada, não crash)."
  def stop_edge_node do
    case Process.whereis(AFL.EdgeNode) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
