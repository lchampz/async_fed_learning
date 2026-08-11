defmodule AFL.Model do
  @moduledoc """
  MLP real (Axon) treinado sobre MNIST, substituindo o `MockML` sintético.

  Cada "rodada local" de um Edge Node é literalmente um passo de treino
  (algumas épocas de SGD sobre o shard non-IID local do nó), a partir dos
  pesos globais atuais — não mais um tensor de ruído gaussiano.
  """

  @hidden_units 32
  @num_classes 10

  # Camada final sem softmax (logits) — evita o caminho especial de
  # "softmax_cross_entropy_from_logits" do Axon, que não é compatível com
  # `sparse: true`. argmax(logits) == argmax(softmax(logits)), então nada
  # se perde para avaliação; a perda usa `from_logits: true` explicitamente.
  def build do
    Axon.input("input", shape: {nil, AFL.Data.image_dim()})
    |> Axon.dense(@hidden_units, activation: :relu)
    |> Axon.dense(@num_classes)
  end

  @doc """
  Inicializa os pesos do modelo. Sem `seed`, `Axon.build/2` usa
  `:erlang.system_time()` como seed padrão — cada chamada gera pesos
  iniciais diferentes, tornando qualquer experimento que dependa desta
  função não-reprodutível entre execuções. Passe um `seed` inteiro fixo
  para inicialização determinística (usado por `AFL.Experiments` para
  reprodutibilidade bit-a-bit entre reexecuções).
  """
  def init_params(seed \\ nil) do
    opts = if seed, do: [seed: seed], else: []
    {init_fn, _predict_fn} = Axon.build(build(), opts)
    init_fn.(Nx.template({1, AFL.Data.image_dim()}, :f32), Axon.ModelState.empty())
  end

  # Variante de escala maior, usada apenas pelo microbenchmark de overhead
  # de checkpoint (Seção de Limitações do artigo, item "Escala do Modelo")
  # --- não usada em nenhum experimento de treino/convergência, só para
  # medir se o overhead de `:ets.insert` escala como assumido (linear) ou
  # não, contra um modelo ordens de grandeza maior que o MLP 784→32→10
  # usado nos Experimentos B/D/G.
  @large_hidden_units_1 1024
  @large_hidden_units_2 512

  def build_large do
    Axon.input("input", shape: {nil, AFL.Data.image_dim()})
    |> Axon.dense(@large_hidden_units_1, activation: :relu)
    |> Axon.dense(@large_hidden_units_2, activation: :relu)
    |> Axon.dense(@num_classes)
  end

  def init_params_large(seed \\ nil) do
    opts = if seed, do: [seed: seed], else: []
    {init_fn, _predict_fn} = Axon.build(build_large(), opts)
    init_fn.(Nx.template({1, AFL.Data.image_dim()}, :f32), Axon.ModelState.empty())
  end

  def loss_fn(y_true, y_pred) do
    Axon.Losses.categorical_cross_entropy(y_true, y_pred,
      sparse: true,
      from_logits: true,
      reduction: :mean
    )
  end

  @doc """
  Treina localmente a partir de `params` (pesos globais recebidos do
  Aggregator) sobre (images, labels) do shard local do nó, e retorna os
  pesos atualizados. Simula o ciclo "baixa modelo global → treina localmente
  → envia atualização" de um Edge Node real.
  """
  def local_train(params, images, labels, opts \\ []) do
    epochs = Keyword.get(opts, :epochs, 1)
    batch_size = Keyword.get(opts, :batch_size, 32)
    learning_rate = Keyword.get(opts, :learning_rate, 0.1)

    data = batches(images, labels, batch_size)

    build()
    |> Axon.Loop.trainer(&loss_fn/2, Polaris.Optimizers.sgd(learning_rate: learning_rate), log: 0)
    |> Axon.Loop.run(data, params, epochs: epochs, compiler: EXLA)
  end

  def predict(params, images) do
    {_init_fn, predict_fn} = Axon.build(build())
    predict_fn.(params, images)
  end

  @doc "Acurácia e loss sobre um conjunto de avaliação (ex: held-out test set)."
  def evaluate(params, images, labels) do
    predictions = predict(params, images)
    predicted_classes = Nx.argmax(predictions, axis: 1)

    correct =
      predicted_classes
      |> Nx.equal(labels)
      |> Nx.sum()
      |> Nx.to_number()

    total = Nx.axis_size(labels, 0)
    loss = predictions |> then(&loss_fn(labels, &1)) |> Nx.to_number()

    %{accuracy: correct / total, loss: loss}
  end

  defp batches(images, labels, batch_size) do
    n = Nx.axis_size(images, 0)
    n_batches = max(div(n, batch_size), 1)

    Enum.map(0..(n_batches - 1), fn i ->
      start = i * batch_size
      size = min(batch_size, n - start)

      {
        Nx.slice_along_axis(images, start, size, axis: 0),
        Nx.slice_along_axis(labels, start, size, axis: 0)
      }
    end)
  end
end
