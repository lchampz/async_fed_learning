defmodule AFL.Data do
  @moduledoc """
  Carrega o MNIST e particiona entre os Edge Nodes simulados.

  Partição non-IID via shards ordenados por label (McMahan et al., 2017,
  "non-IID" setting): amostras são ordenadas por classe, divididas em shards,
  e cada nó recebe `shards_per_node` shards — de modo que cada EN vê
  majoritariamente 1-2 dígitos, e não uma amostra representativa das 10
  classes.
  """

  @image_dim 28 * 28

  def image_dim, do: @image_dim

  @doc """
  Retorna %{train: {images, labels}, test: {images, labels}}.
  Imagens normalizadas para [0,1] e achatadas para {n, 784}.
  Labels como inteiros {n} (não one-hot — Axon.Losses aceita sparse).

  `train_size`/`test_size` sub-amostram o MNIST completo para manter os
  experimentos (muitas repetições × muitos nós) rápidos em CPU commodity.
  """
  def load(opts \\ []) do
    train_size = Keyword.get(opts, :train_size, 6_000)
    test_size = Keyword.get(opts, :test_size, 1_000)

    {train_images, train_labels} = Scidata.MNIST.download()
    {test_images, test_labels} = Scidata.MNIST.download_test()

    {train_x, train_y} = prep(train_images, train_labels, train_size)
    {test_x, test_y} = prep(test_images, test_labels, test_size)

    %{train: {train_x, train_y}, test: {test_x, test_y}}
  end

  defp prep({binary, type, shape}, {label_binary, label_type, _label_shape}, n) do
    {total, _c, h, w} = shape

    take = min(n, total)

    images =
      binary
      |> Nx.from_binary(type)
      |> Nx.reshape({total, h * w})
      |> Nx.slice_along_axis(0, take, axis: 0)
      |> Nx.divide(255.0)
      |> Nx.as_type(:f32)

    labels =
      label_binary
      |> Nx.from_binary(label_type)
      |> Nx.slice_along_axis(0, take, axis: 0)
      |> Nx.as_type(:s64)

    {images, labels}
  end

  @doc """
  Particiona (images, labels) em `num_nodes` conjuntos non-IID por shard de
  classe. Retorna uma lista de {images_k, labels_k}, uma por nó.

  `shards_per_node` controla o grau de heterogeneidade: 1 = cada nó vê
  essencialmente 1-2 classes; valores maiores aproximam o IID.
  """
  def partition_non_iid(images, labels, num_nodes, shards_per_node \\ 2) do
    n = Nx.axis_size(images, 0)
    labels_list = Nx.to_flat_list(labels)

    # Ordena índices por label — agrupa classes contiguamente
    sorted_idx =
      Enum.zip(labels_list, 0..(n - 1))
      |> Enum.sort_by(fn {label, _idx} -> label end)
      |> Enum.map(fn {_label, idx} -> idx end)

    num_shards = num_nodes * shards_per_node
    shard_size = div(n, num_shards)

    shards =
      sorted_idx
      |> Enum.chunk_every(shard_size)
      |> Enum.take(num_shards)
      |> Enum.shuffle()

    shard_groups = Enum.chunk_every(shards, shards_per_node)

    Enum.map(shard_groups, fn node_shards ->
      idx = node_shards |> List.flatten() |> Enum.shuffle()
      idx_tensor = Nx.tensor(idx, type: :s64)
      {Nx.take(images, idx_tensor, axis: 0), Nx.take(labels, idx_tensor, axis: 0)}
    end)
  end
end
