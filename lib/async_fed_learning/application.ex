defmodule AFL.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ModelKeeper e BufferKeeper precisam iniciar ANTES de quem os
      # reivindica no próprio init/1 (Aggregator e EdgeNode, respectivamente).
      AFL.ModelKeeper,
      {AFL.Aggregator, MockML.initial_weights()},
      AFL.BufferKeeper,
      AFL.EdgeNodeSupervisor
    ]

    # max_restarts/max_seconds acima do default (3 em 5s): este sistema é
    # deliberadamente submetido a testes de caos (Experimento H) que matam
    # processos supervisionados repetidamente em rajada — com o default, a
    # própria suite de testes esgota o orçamento de restart e derruba a
    # aplicação inteira (mascarando falhas reais como "crash da suite").
    opts = [strategy: :one_for_one, name: AFL.Supervisor, max_restarts: 100, max_seconds: 10]
    Supervisor.start_link(children, opts)
  end
end
