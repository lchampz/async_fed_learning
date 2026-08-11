defmodule AFL.Baselines do
  @moduledoc """
  Implementações simplificadas de SSP (Ho et al., 2013) e FedAsync (Xie et
  al., 2019) para comparação empírica direta com o AFL no mesmo harness
  (Experimento F) — até aqui essas abordagens eram apenas discutidas
  qualitativamente (Seção II do artigo).

  Não são reimplementações completas dos papers originais, mas capturam o
  mecanismo central de cada um:

    * SSP: barreira de staleness limitada — um nó só pode avançar para a
      próxima rodada se seu contador de rodadas não estiver mais que
      `bound` rodadas na frente do nó mais lento. Ao contrário do AFL
      (assincronia irrestrita + penalidade), SSP força espera ativa.

    * FedAsync: mistura convexa de peso FIXO (não ponderado por tamanho de
      amostra $n_k$) com decaimento por staleness:
      $W_{t+1} = (1-\\alpha_t) W_t + \\alpha_t W_k$, $\\alpha_t = \\alpha_0 \\cdot f(\\delta)$.
      Ao contrário do AFL, um update de um nó com $n_k$ grande não pesa mais
      que um com $n_k$ pequeno.
  """

  @doc """
  SSP: verifica se um nó cujo contador de rodadas é `node_round` pode
  avançar, dado o contador de rodadas de todos os nós (`all_rounds`) e o
  limite de staleness `bound`. Retorna `false` enquanto o nó estiver mais
  de `bound` rodadas na frente do nó mais lento — a chamada deve então
  aguardar e tentar novamente (barreira de staleness limitada).
  """
  def ssp_can_advance?(node_round, all_rounds, bound) do
    node_round - Enum.min(all_rounds) <= bound
  end

  @doc """
  FedAsync: mistura convexa de peso fixo `alpha0`, atenuado pela mesma
  função de staleness usada no AFL (para comparação justa) — mas SEM
  ponderação por `n_k`, que é a diferença estrutural chave frente ao AFL.
  """
  def fedasync_merge(w_old, w_new, alpha0, gap, staleness_fn \\ &(1.0 / (1 + &1))) do
    alpha_t = alpha0 * staleness_fn.(gap)
    AFL.Aggregator.convex_combine(w_old, w_new, 1.0 - alpha_t, alpha_t)
  end
end
