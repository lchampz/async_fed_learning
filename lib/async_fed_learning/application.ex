defmodule AFL.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Garante que cada execução da BEAM (cada `mix test`, cada rodada de
    # experimento) comece de um checkpoint em disco limpo — sem isso, um
    # arquivo deixado por uma execução anterior contaminaria o estado
    # inicial "reprodutível" da execução atual (ver AFL.ModelKeeper).
    AFL.ModelKeeper.clear_checkpoint!()

    # Posse invertida (Experimento R5): ModelKeeper/BufferKeeper possuem
    # suas tabelas ETS permanentemente e nunca as repassam — Aggregator e
    # EdgeNodeSupervisor apenas leem/escrevem nelas pelo nome, então o
    # crash de um worker nunca mais toca a tabela do seu dono. O que
    # `:rest_for_one` ainda precisa garantir é a direção oposta: se o DONO
    # cai, o worker correspondente cai e reinicia em cascata, de forma
    # consistente (nunca rodando contra uma tabela que não existe mais).
    # Os dois pares (modelo, buffer) são independentes entre si — por isso
    # cada um vive em seu próprio Supervisor `:rest_for_one`, e não há
    # cascata cruzada entre eles.
    model_children = [AFL.ModelKeeper, {AFL.Aggregator, MockML.initial_weights()}]
    buffer_children = [AFL.BufferKeeper, AFL.EdgeNodeSupervisor]

    # max_restarts/max_seconds acima do default (3 em 5s): este sistema é
    # deliberadamente submetido a testes de caos (Experimento R) que matam
    # processos supervisionados repetidamente em rajada — com o default, a
    # própria suite de testes esgota o orçamento de restart e derruba a
    # aplicação inteira (mascarando falhas reais como "crash da suite").
    sup_opts = [max_restarts: 100, max_seconds: 10]

    children = [
      %{
        id: AFL.ModelSupervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [model_children, [strategy: :rest_for_one, name: AFL.ModelSupervisor] ++ sup_opts]}
      },
      %{
        id: AFL.BufferSupervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [buffer_children, [strategy: :rest_for_one, name: AFL.BufferSupervisor] ++ sup_opts]}
      }
    ]

    opts = [strategy: :one_for_one, name: AFL.Supervisor] ++ sup_opts
    Supervisor.start_link(children, opts)
  end
end
