defmodule AFL.Experiments do
  @moduledoc """
  Bateria de experimentos para validação científica do AFL.
  Gera CSVs em ./results/ para análise estatística e figuras do artigo.

  Uso:
    iex -S mix
    AFL.Experiments.run_all()
  """

  require Logger

  @results_dir "results"
  # K nós simulados com latências heterogêneas (ms) — straggler é o último
  @node_latencies [10, 10, 20, 50, 500]
  @n_nodes length(@node_latencies)
  @duration_ms 5_000
  @repetitions 10

  # -------------------------------------------------------------------
  # Entry point
  # -------------------------------------------------------------------

  def run_all do
    File.mkdir_p!(@results_dir)
    # Silencia logs de info/debug durante coleta — só warnings aparecem
    Logger.configure(level: :warning)

    IO.puts("\n╔══════════════════════════════════════════════╗")
    IO.puts("║  AFL — Bateria de Experimentos Científicos   ║")
    IO.puts("╚══════════════════════════════════════════════╝\n")

    exp_a = experiment_a_throughput()
    exp_b = experiment_b_staleness()
    exp_c = experiment_c_buffer()
    exp_d = experiment_d_convergence()
    exp_e = experiment_e_memory_overhead()
    exp_f = experiment_f_ssp_throughput()
    exp_g = experiment_g_fedasync_convergence()
    exp_h = experiment_h_resilience()
    exp_r4 = experiment_r4_concurrent_crash()
    exp_r5 = experiment_r5_heir_crash_race()
    exp_scale = experiment_scale_checkpoint_overhead()

    Logger.configure(level: :info)

    IO.puts("\n✓ Todos os experimentos concluídos.")
    IO.puts("  Resultados em ./#{@results_dir}/\n")

    %{
      exp_a: exp_a, exp_b: exp_b, exp_c: exp_c, exp_d: exp_d, exp_e: exp_e,
      exp_f: exp_f, exp_g: exp_g, exp_h: exp_h, exp_r4: exp_r4, exp_r5: exp_r5,
      exp_scale: exp_scale
    }
  end

  # -------------------------------------------------------------------
  # Exp A — Throughput: FedAvg Async vs Sync com stragglers
  #
  # Cenário: K=5 nós com latências [10,10,20,50,500] ms.
  # Sync:  cada rodada aguarda TODOS os nós → tempo = max(latências) = 500ms
  # Async: cada nó envia independentemente → throughput = Σ(1/latência_k)
  # -------------------------------------------------------------------

  def experiment_a_throughput do
    banner("A", "Throughput Async vs Sync — #{@n_nodes} nós, #{@duration_ms}ms")

    rows =
      Enum.flat_map(1..@repetitions, fn rep ->
        progress("A", rep, @repetitions)
        AFL.Aggregator.reset(MockML.initial_weights())

        async_result = run_async(Map.new(Enum.with_index(@node_latencies, 1)))
        AFL.Aggregator.reset(MockML.initial_weights())
        sync_result = run_sync(@node_latencies)

        Enum.map(@node_latencies, fn lat ->
          node_id = Enum.find_index(@node_latencies, &(&1 == lat)) + 1
          %{
            repetition: rep,
            node_id: node_id,
            node_latency_ms: lat,
            async_total_updates: async_result.updates_count,
            async_elapsed_ms: async_result.elapsed_ms,
            async_updates_per_s: Float.round(async_result.updates_count / async_result.elapsed_ms * 1000, 2),
            sync_rounds: sync_result.rounds,
            sync_elapsed_ms: sync_result.elapsed_ms,
            sync_updates_per_s: Float.round(sync_result.rounds * @n_nodes / sync_result.elapsed_ms * 1000, 2),
            speedup: Float.round(async_result.updates_count / max(sync_result.rounds * @n_nodes, 1), 2)
          }
        end)
      end)

    export_csv(rows, "#{@results_dir}/exp_a_throughput.csv")
    summary_a(rows)
    rows
  end

  # Async: cada nó é uma Task independente que envia a cada latência_k ms
  defp run_async(nodes) do
    AFL.Aggregator.reset(MockML.initial_weights())
    start = System.monotonic_time(:millisecond)
    deadline = start + @duration_ms

    tasks =
      Enum.map(nodes, fn {latency, _id} ->
        Task.async(fn -> send_loop_async(latency, deadline) end)
      end)

    Enum.each(tasks, &Task.await(&1, @duration_ms + 2000))
    elapsed = System.monotonic_time(:millisecond) - start
    state = AFL.Aggregator.get_state()
    %{updates_count: state.updates_count, elapsed_ms: elapsed}
  end

  defp send_loop_async(latency_ms, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      :timer.sleep(latency_ms)
      AFL.Aggregator.update(MockML.train(), 100)
      send_loop_async(latency_ms, deadline)
    end
  end

  # Sync: a cada rodada, TODOS os nós enviam em paralelo e o "servidor"
  # só avança quando o último responde (simula barreira síncrona)
  defp run_sync(latencies) do
    start = System.monotonic_time(:millisecond)
    deadline = start + @duration_ms

    rounds = sync_round_loop(latencies, deadline, 0)
    elapsed = System.monotonic_time(:millisecond) - start
    %{rounds: rounds, elapsed_ms: elapsed}
  end

  defp sync_round_loop(latencies, deadline, rounds) do
    if System.monotonic_time(:millisecond) >= deadline do
      rounds
    else
      # Todos os K nós treinam em paralelo — barreira: aguarda o mais lento
      tasks =
        Enum.map(latencies, fn lat ->
          Task.async(fn ->
            :timer.sleep(lat)
            AFL.Aggregator.update_sync(MockML.train(), 100)
          end)
        end)

      Enum.each(tasks, &Task.await(&1, 5000))
      sync_round_loop(latencies, deadline, rounds + 1)
    end
  end

  defp summary_a(rows) do
    async_ups = rows |> Enum.map(& &1.async_updates_per_s) |> Enum.uniq() |> mean()
    sync_ups  = rows |> Enum.map(& &1.sync_updates_per_s)  |> Enum.uniq() |> mean()
    speedup   = rows |> Enum.map(& &1.speedup) |> Enum.uniq() |> mean()

    IO.puts("  → Async: #{Float.round(async_ups, 1)} upd/s | " <>
            "Sync: #{Float.round(sync_ups, 1)} upd/s | " <>
            "Speedup médio: #{Float.round(speedup, 2)}×")
  end

  # -------------------------------------------------------------------
  # Exp B — Staleness: Bias por Função de Penalidade (treino real)
  #
  # Substitui o antigo "poison update" sintético (W_k=999 fixo, sem
  # aleatoriedade real) por um cenário de staleness genuíno:
  #   1. Pré-treina um modelo "fresco" via FedAvg real sobre partições
  #      non-IID do MNIST entre os 5 nós.
  #   2. Um nó "atrasado" baixa esse modelo fresco e treina localmente
  #      (SGD real sobre seu shard) — essa atualização, `stale_weights`,
  #      não depende do gap.
  #   3. Simula-se uma trajetória de avanço real do agregador (outros nós
  #      treinando e enviando updates frescos) até o gap máximo, tirando
  #      snapshots {pesos, total} em cada gap intermediário.
  #   4. Para cada gap e cada função de penalidade, aplica-se a mesma
  #      atualização atrasada `stale_weights` (via `fedavg_merge/4`, sem
  #      mutar o processo) sobre o snapshot daquele gap, medindo o bias
  #      real em acurácia/loss de validação.
  # A variância entre repetições agora vem de fontes estocásticas reais
  # (ordem de mini-batches, seleção do nó atrasado, seleção dos nós que
  # avançam o modelo) — não de uma simulação determinística.
  # -------------------------------------------------------------------

  # Exp. B usa mais repetições que as demais: a única fonte de aleatoriedade
  # entre repetições é qual nó (dentre 4) avança o modelo em cada rodada de
  # `advance_trajectory/3` — uma fonte de variância estreita. Com apenas 10
  # repetições, a ANOVA num gap intermediário isolado (δ=10) se mostrou
  # instável entre reexecuções (F variou de 1,2 a 6,6, p de 0,32 a 0,001 em
  # reruns independentes do mesmo código) — poder estatístico insuficiente,
  # não um efeito real oscilando. 30 repetições estabilizam a estimativa.
  @b_repetitions 30

  def experiment_b_staleness do
    banner("B", "Staleness — Bias por função de penalidade vs gap (MNIST real)")

    penalty_fns = [
      {:hyperbolic,     fn d -> 1.0 / (1 + d) end},
      {:exponential_05, fn d -> :math.exp(-0.5 * d) end},
      {:exponential_01, fn d -> :math.exp(-0.1 * d) end},
      {:no_penalty,     fn _ -> 1.0 end}
    ]

    gaps = [0, 1, 2, 3, 5, 8, 10, 15, 20]
    max_gap = Enum.max(gaps)
    pretrain_rounds = 15

    # Partição e pré-treino do modelo "fresco" acontecem uma única vez, fora
    # do loop de repetições — seed fixa e versionada garante que ambos sejam
    # idênticos bit-a-bit em qualquer reexecução.
    seed_rand!(:exp_b_setup, 0)

    data = AFL.Data.load(train_size: 4_000, test_size: 800)
    {test_x, test_y} = data.test
    {train_x, train_y} = data.train
    nodes = AFL.Data.partition_non_iid(train_x, train_y, @n_nodes, 2)

    fresh = pretrain_fresh_model(nodes, pretrain_rounds, seed_for(:exp_b_setup, 0))

    rows =
      Enum.flat_map(1..@b_repetitions, fn rep ->
        progress("B", rep, @b_repetitions)
        # Única fonte de aleatoriedade por repetição: qual nó avança o
        # modelo em cada rodada de advance_trajectory/3 (Enum.random).
        seed_rand!(:exp_b, rep)

        stale_idx = rem(rep - 1, @n_nodes)
        {stale_x, stale_y} = Enum.at(nodes, stale_idx)
        other_nodes = List.delete_at(nodes, stale_idx)

        # Atualização atrasada: computada a partir do modelo fresco, mas só
        # aplicada mais tarde (é isso que gera o gap) — não depende de `gap`.
        stale_weights =
          AFL.Model.local_train(fresh.weights, stale_x, stale_y,
            epochs: 1,
            batch_size: 16,
            learning_rate: 0.3
          )

        n_stale = Nx.axis_size(stale_x, 0)

        trajectory = advance_trajectory(fresh, other_nodes, max_gap)

        Enum.map(gaps, fn gap ->
          snapshot = Map.fetch!(trajectory, gap)
          metrics_before = AFL.Model.evaluate(snapshot.weights, test_x, test_y)

          Enum.map(penalty_fns, fn {fn_name, pfn} ->
            staleness_factor = pfn.(gap)
            effective_nk = n_stale * staleness_factor

            {merged_weights, _total} =
              AFL.Aggregator.fedavg_merge(snapshot.weights, snapshot.total, stale_weights, effective_nk)

            metrics_after = AFL.Model.evaluate(merged_weights, test_x, test_y)

            %{
              penalty_fn: fn_name,
              staleness_gap: gap,
              repetition: rep,
              staleness_factor: Float.round(staleness_factor, 5),
              loss_before: Float.round(metrics_before.loss, 5),
              loss_after: Float.round(metrics_after.loss, 5),
              bias_loss: Float.round(metrics_after.loss - metrics_before.loss, 5),
              accuracy_before: Float.round(metrics_before.accuracy, 5),
              accuracy_after: Float.round(metrics_after.accuracy, 5),
              accuracy_drop: Float.round(metrics_before.accuracy - metrics_after.accuracy, 5)
            }
          end)
        end)
      end)
      |> List.flatten()

    export_csv(rows, "#{@results_dir}/exp_b_staleness.csv")

    IO.puts(
      "  → #{length(rows)} pontos coletados (#{length(penalty_fns)} funções × " <>
        "#{length(gaps)} gaps × #{@repetitions} reps, treino real MNIST non-IID)"
    )

    rows
  end

  # Treina o modelo global do zero via FedAvg real por `rounds` rodadas,
  # todas os nós contribuindo — usado como ponto de referência "fresco".
  defp pretrain_fresh_model(nodes, rounds, seed) do
    AFL.Aggregator.reset(AFL.Model.init_params(seed))

    Enum.each(1..rounds, fn _round ->
      Enum.each(nodes, fn {x, y} ->
        global = AFL.Aggregator.get_model()
        updated = AFL.Model.local_train(global, x, y, epochs: 1, batch_size: 16, learning_rate: 0.3)
        AFL.Aggregator.update_sync(updated, Nx.axis_size(x, 0))
      end)
    end)

    state = AFL.Aggregator.get_state()
    %{weights: state.weights, total: state.total, version: state.version}
  end

  # Restaura o agregador ao snapshot "fresco" e avança `max_gap` rodadas
  # reais (nó aleatório entre `other_nodes` a cada rodada), tirando um
  # snapshot {weights, total} a cada gap intermediário — reaproveitado por
  # todos os gaps e funções de penalidade da mesma repetição.
  defp advance_trajectory(fresh, other_nodes, max_gap) do
    AFL.Aggregator.restore(fresh)

    Enum.reduce(0..max_gap, %{0 => fresh}, fn gap, acc ->
      if gap == 0 do
        acc
      else
        {x, y} = Enum.random(other_nodes)
        global = AFL.Aggregator.get_model()
        updated = AFL.Model.local_train(global, x, y, epochs: 1, batch_size: 16, learning_rate: 0.3)
        AFL.Aggregator.update_sync(updated, Nx.axis_size(x, 0))

        state = AFL.Aggregator.get_state()
        snapshot = %{weights: state.weights, total: state.total, version: state.version}
        Map.put(acc, gap, snapshot)
      end
    end)
  end

  # -------------------------------------------------------------------
  # Exp C — Ring Buffer: Preservação sob Desconexões
  # -------------------------------------------------------------------

  # Tamanhos de buffer comparados sob a MESMA simulação estocástica —
  # substitui a antiga baseline "Sem Buffer" analítica (que era apenas
  # 1 - taxa_desconexão por construção, não uma simulação). `:unbounded`
  # usa `total_rounds` como capacidade — não pode dar overflow no horizonte
  # simulado, servindo de teto superior real para o ganho do ring buffer.
  @buffer_sizes [0, 5, 20, :unbounded]

  def experiment_c_buffer do
    banner("C", "Ring Buffer — Preservação por tamanho de buffer × taxa de desconexão")

    rates = [0.0, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0]
    total_rounds = 100

    rows =
      for buffer_size <- @buffer_sizes, rate <- rates, rep <- 1..@repetitions do
        max_buf = if buffer_size == :unbounded, do: total_rounds, else: buffer_size

        # Seed pela repetição apenas (não por buffer_size/rate): todo
        # buffer_size e toda rate para a mesma `rep` veem exatamente a
        # mesma sequência simulada de conexão/desconexão — reprodutível
        # entre execuções e, como efeito colateral desejável, uma
        # comparação pareada entre tamanhos de buffer e taxas.
        seed_rand!(:exp_c, rep)

        AFL.Aggregator.reset(MockML.initial_weights())
        {sent, flushed, dropped} = simulate_channel(total_rounds, rate, max_buf)

        total_useful = sent + flushed
        preservation = if (flushed + dropped) > 0, do: flushed / (flushed + dropped), else: 1.0
        effective    = total_useful / total_rounds

        %{
          buffer_size: buffer_size,
          disconnect_rate: rate,
          repetition: rep,
          total_rounds: total_rounds,
          sent_directly: sent,
          flushed_from_buffer: flushed,
          dropped_overflow: dropped,
          total_useful_updates: total_useful,
          preservation_ratio: Float.round(preservation, 4),
          effective_update_ratio: Float.round(effective, 4)
        }
      end

    export_csv(rows, "#{@results_dir}/exp_c_buffer.csv")

    IO.puts("  Buffer | Disconnect% | Preservação | Efetividade")
    IO.puts("  " <> String.duplicate("─", 50))

    for buffer_size <- @buffer_sizes do
      grp_buf = Enum.filter(rows, &(&1.buffer_size == buffer_size))
      by_rate = Enum.group_by(grp_buf, & &1.disconnect_rate)

      for {rate, grp} <- Enum.sort(by_rate) do
        pres = grp |> Enum.map(& &1.preservation_ratio) |> mean() |> Float.round(3)
        eff  = grp |> Enum.map(& &1.effective_update_ratio) |> mean() |> Float.round(3)
        IO.puts("  #{buffer_size}      | #{Float.round(rate * 100, 0)}%         | #{pres}       | #{eff}")
      end
    end

    rows
  end

  defp simulate_channel(rounds, disc_rate, max_buf) do
    Enum.reduce(1..rounds, {0, 0, 0, []}, fn _round, {sent, flushed, dropped, buf} ->
      connected = :rand.uniform() > disc_rate

      if connected do
        # Flush buffer primeiro, depois envia update novo
        flush_count = length(buf)
        Enum.each(buf, fn w -> AFL.Aggregator.update_sync(w, 100) end)
        AFL.Aggregator.update_sync(MockML.train(), 100)
        {sent + 1, flushed + flush_count, dropped, []}
      else
        w = MockML.train()

        cond do
          max_buf == 0 ->
            # Sem capacidade alguma — todo update gerado offline é perdido
            {sent, flushed, dropped + 1, buf}

          length(buf) < max_buf ->
            {sent, flushed, dropped, buf ++ [w]}

          true ->
            # Ring: remove o mais antigo, insere o novo
            [_ | rest] = buf
            {sent, flushed, dropped + 1, rest ++ [w]}
        end
      end
    end)
    |> then(fn {s, f, d, _} -> {s, f, d} end)
  end

  # -------------------------------------------------------------------
  # Exp D — Convergência: FedAvg real sobre MNIST non-IID
  #
  # Substitui a curva sintética (gradiente apontando diretamente para
  # W*=5 com ruído gaussiano — convergência trivial por álgebra da média
  # móvel) por rodadas reais de FedAvg: a cada rodada, um nó treina
  # localmente (SGD real) sobre seu shard non-IID e envia a atualização;
  # mede-se acurácia/loss de validação real após cada rodada.
  # -------------------------------------------------------------------

  def experiment_d_convergence do
    banner("D", "Convergência — acurácia/loss real ao longo das rodadas (MNIST non-IID)")

    n_rounds = 150
    data = AFL.Data.load(train_size: 4_000, test_size: 800)
    {test_x, test_y} = data.test
    {train_x, train_y} = data.train

    rows =
      Enum.flat_map(1..@repetitions, fn rep ->
        progress("D", rep, @repetitions)

        # Seed única cobre a partição non-IID (Enum.shuffle), a seleção de
        # nó por rodada (Enum.random) e os pesos iniciais do modelo (PRNG
        # independente do Axon) — toda a repetição é reprodutível.
        seed = seed_rand!(:exp_d, rep)
        nodes = AFL.Data.partition_non_iid(train_x, train_y, @n_nodes, 2)
        AFL.Aggregator.reset(AFL.Model.init_params(seed))

        Enum.map(1..n_rounds, fn round_idx ->
          {x, y} = Enum.random(nodes)
          global = AFL.Aggregator.get_model()
          updated = AFL.Model.local_train(global, x, y, epochs: 1, batch_size: 16, learning_rate: 0.3)
          AFL.Aggregator.update_sync(updated, Nx.axis_size(x, 0))

          metrics = AFL.Model.evaluate(AFL.Aggregator.get_model(), test_x, test_y)

          %{
            repetition: rep,
            round: round_idx,
            accuracy: Float.round(metrics.accuracy, 5),
            loss: Float.round(metrics.loss, 5),
            version: AFL.Aggregator.get_version()
          }
        end)
      end)

    export_csv(rows, "#{@results_dir}/exp_d_convergence.csv")

    # Rodada em que acurácia >= 0.5 pela primeira vez (média entre reps)
    converge_rounds =
      rows
      |> Enum.group_by(& &1.repetition)
      |> Enum.map(fn {_rep, rep_rows} ->
        first = Enum.find(rep_rows, fn r -> r.accuracy >= 0.5 end)
        if first, do: first.round, else: n_rounds
      end)

    final_acc = rows |> Enum.filter(&(&1.round == n_rounds)) |> Enum.map(& &1.accuracy) |> mean()

    IO.puts(
      "  → Acurácia final média: #{Float.round(final_acc, 3)} | " <>
        "Rodadas até acc≥0.5: ~#{round(mean(converge_rounds))} em média"
    )

    rows
  end

  # -------------------------------------------------------------------
  # Exp E — Overhead real de memória do Ring Buffer ETS
  #
  # A Seção de Limitações do paper especulava que a ETS "pode tornar-se
  # gargalo de memória para tensores grandes" sem medir nada. Aqui
  # medimos o overhead real: mesmo buffer (`@max_buffer=5` do EdgeNode),
  # comparando pesos sintéticos d=10 contra os pesos reais do MLP
  # (784→32→10) usado nos Exp. B/D.
  # -------------------------------------------------------------------

  # Capacidade do ring buffer do EdgeNode (ver @max_buffer em lib/edge_node.ex)
  @ring_buffer_capacity 5

  def experiment_e_memory_overhead do
    banner("E", "Overhead de memória do Ring Buffer — sintético (d=10) vs modelo real (MLP MNIST)")

    # Medido analiticamente via Nx.byte_size (soma recursiva dos tensores de
    # parâmetros), não via :ets.info(:memory): com backends como EXLA, um
    # Nx.Tensor guardado em ETS é uma referência de tamanho fixo a um buffer
    # nativo fora do heap, e binários grandes (refc binaries) do próprio
    # Nx.BinaryBackend também não são contabilizados inline pela tabela —
    # ambos os caminhos subestimariam brutalmente o footprint real. O que
    # importa para a discussão de "gargalo de memória" é o tamanho real dos
    # parâmetros do modelo, que é isso que este cálculo mede.
    weight_kinds = [
      {:synthetic_d10, MockML.initial_weights()},
      {:real_mlp_mnist, AFL.Model.init_params()}
    ]

    rows =
      Enum.map(weight_kinds, fn {label, weights} ->
        per_entry_bytes = tensor_byte_size(weights)
        buffer_bytes = per_entry_bytes * @ring_buffer_capacity

        %{
          weight_kind: label,
          buffer_capacity: @ring_buffer_capacity,
          bytes_per_entry: per_entry_bytes,
          buffer_total_bytes: buffer_bytes,
          buffer_total_kb: Float.round(buffer_bytes / 1024, 2)
        }
      end)

    export_csv(rows, "#{@results_dir}/exp_e_memory.csv")

    Enum.each(rows, fn r ->
      IO.puts(
        "  → #{r.weight_kind}: #{r.bytes_per_entry} bytes/entrada × #{r.buffer_capacity} slots " <>
          "≈ #{r.buffer_total_kb} KB no ring buffer"
      )
    end)

    rows
  end

  defp tensor_byte_size(%Axon.ModelState{} = ms), do: tensor_byte_size(ms.data)
  defp tensor_byte_size(%Nx.Tensor{} = t), do: Nx.byte_size(t)

  defp tensor_byte_size(map) when is_map(map),
    do: map |> Map.values() |> Enum.map(&tensor_byte_size/1) |> Enum.sum()

  defp tensor_param_count(%Axon.ModelState{} = ms), do: tensor_param_count(ms.data)
  defp tensor_param_count(%Nx.Tensor{} = t), do: Nx.size(t)

  defp tensor_param_count(map) when is_map(map),
    do: map |> Map.values() |> Enum.map(&tensor_param_count/1) |> Enum.sum()

  # -------------------------------------------------------------------
  # Exp Escala — Overhead de checkpoint em modelo ordens de grandeza maior
  #
  # A Seção de Limitações especulava que o overhead de `:ets.insert`
  # (medido em ≈5,5% para o MLP de 25.450 parâmetros usado nos demais
  # experimentos) "tende a crescer com o tamanho do estado serializado",
  # sem medir além dessa única arquitetura pequena. Mede-se aqui o mesmo
  # overhead — tempo de `:ets.insert` do snapshot completo do estado —
  # para um MLP ordens de grandeza maior (784→1024→512→10,
  # `AFL.Model.build_large/0`), confirmando ou refutando a extrapolação
  # linear assumida.
  # -------------------------------------------------------------------

  @checkpoint_bench_iterations 5_000

  def experiment_scale_checkpoint_overhead do
    banner("Escala", "Overhead de checkpoint — MLP pequeno vs MLP grande")

    small_params = AFL.Model.init_params(42)
    large_params = AFL.Model.init_params_large(42)

    rows = [
      benchmark_checkpoint(:small, small_params),
      benchmark_checkpoint(:large, large_params)
    ]

    export_csv(rows, "#{@results_dir}/exp_scale_checkpoint.csv")

    Enum.each(rows, fn r ->
      IO.puts(
        "  → #{r.model}: #{r.param_count} params (#{r.bytes_per_entry} bytes) — " <>
          "#{r.us_per_insert} μs/insert (média de #{@checkpoint_bench_iterations} chamadas)"
      )
    end)

    rows
  end

  # Mede o tempo de `:ets.insert/2` do estado completo do modelo numa
  # tabela isolada e descartável — a mesma operação exata que
  # `AFL.ModelKeeper.checkpoint/1` faz em produção, sem o overhead do
  # FedAvg merge em si, para isolar especificamente o custo do checkpoint.
  defp benchmark_checkpoint(label, params) do
    table = :ets.new(:checkpoint_bench, [:set, :private])

    {elapsed_us, :ok} =
      :timer.tc(fn ->
        Enum.each(1..@checkpoint_bench_iterations, fn i ->
          :ets.insert(table, {:current, {i, params}})
        end)
      end)

    :ets.delete(table)

    %{
      model: label,
      param_count: tensor_param_count(params),
      bytes_per_entry: tensor_byte_size(params),
      us_per_insert: Float.round(elapsed_us / @checkpoint_bench_iterations, 2)
    }
  end

  # -------------------------------------------------------------------
  # Exp F — Throughput: AFL vs SSP sob o mesmo cenário de stragglers
  #
  # SSP (Ho et al., 2013) permite assincronia limitada por uma barreira de
  # staleness: um nó só avança para a próxima rodada se não estiver mais de
  # `bound` rodadas na frente do nó mais lento (ver AFL.Baselines). Isso o
  # posiciona entre o síncrono puro (bound=0) e o AFL (bound=∞, sem
  # barreira, só penalidade). Mede-se o custo de throughput dessa barreira
  # sob o mesmo cenário de stragglers do Experimento A.
  # -------------------------------------------------------------------

  @ssp_bounds [2, 5, 10, 20]

  def experiment_f_ssp_throughput do
    banner("F", "Throughput AFL vs SSP (barreira de staleness limitada) vs Sync")

    rows =
      Enum.flat_map(1..@repetitions, fn rep ->
        progress("F", rep, @repetitions)

        AFL.Aggregator.reset(MockML.initial_weights())
        async_result = run_async(Map.new(Enum.with_index(@node_latencies, 1)))

        AFL.Aggregator.reset(MockML.initial_weights())
        sync_result = run_sync(@node_latencies)

        ssp_results =
          Map.new(@ssp_bounds, fn bound ->
            AFL.Aggregator.reset(MockML.initial_weights())
            {bound, run_ssp(@node_latencies, bound)}
          end)

        base = %{
          repetition: rep,
          async_updates_per_s: Float.round(async_result.updates_count / async_result.elapsed_ms * 1000, 2),
          sync_updates_per_s: Float.round(sync_result.rounds * @n_nodes / sync_result.elapsed_ms * 1000, 2)
        }

        Enum.map(@ssp_bounds, fn bound ->
          ssp = Map.fetch!(ssp_results, bound)

          Map.merge(base, %{
            ssp_bound: bound,
            ssp_updates_per_s: Float.round(ssp.updates_count / ssp.elapsed_ms * 1000, 2)
          })
        end)
      end)

    export_csv(rows, "#{@results_dir}/exp_f_ssp_throughput.csv")

    async_ups = rows |> Enum.map(& &1.async_updates_per_s) |> Enum.uniq() |> mean()
    sync_ups = rows |> Enum.map(& &1.sync_updates_per_s) |> Enum.uniq() |> mean()

    IO.puts("  → AFL (assíncrono irrestrito): #{Float.round(async_ups, 1)} upd/s")
    IO.puts("  → FedAvg Síncrono:              #{Float.round(sync_ups, 1)} upd/s")

    for bound <- @ssp_bounds do
      grp = Enum.filter(rows, &(&1.ssp_bound == bound))
      ssp_ups = grp |> Enum.map(& &1.ssp_updates_per_s) |> mean()
      IO.puts("  → SSP (bound=#{bound}):                #{Float.round(ssp_ups, 1)} upd/s")
    end

    rows
  end

  # SSP: cada nó só envia se não estiver mais de `bound` rodadas na frente
  # do nó mais lento (barreira de staleness limitada via contador em ETS
  # compartilhado entre as Tasks).
  defp run_ssp(latencies, bound) do
    table = :ets.new(:ssp_rounds, [:set, :public])
    ids = Enum.with_index(latencies, 1)
    Enum.each(ids, fn {_lat, id} -> :ets.insert(table, {id, 0}) end)

    start = System.monotonic_time(:millisecond)
    deadline = start + @duration_ms

    tasks =
      Enum.map(ids, fn {latency, id} ->
        Task.async(fn -> ssp_loop(id, latency, deadline, table, bound) end)
      end)

    Enum.each(tasks, &Task.await(&1, @duration_ms + 5000))
    elapsed = System.monotonic_time(:millisecond) - start
    :ets.delete(table)

    state = AFL.Aggregator.get_state()
    %{updates_count: state.updates_count, elapsed_ms: elapsed}
  end

  defp ssp_loop(id, latency_ms, deadline, table, bound) do
    if System.monotonic_time(:millisecond) < deadline do
      ssp_wait_gate(id, table, bound)
      :timer.sleep(latency_ms)
      AFL.Aggregator.update(MockML.train(), 100)
      [{^id, round}] = :ets.lookup(table, id)
      :ets.insert(table, {id, round + 1})
      ssp_loop(id, latency_ms, deadline, table, bound)
    end
  end

  defp ssp_wait_gate(id, table, bound) do
    [{^id, my_round}] = :ets.lookup(table, id)
    all_rounds = table |> :ets.tab2list() |> Enum.map(fn {_, r} -> r end)

    if AFL.Baselines.ssp_can_advance?(my_round, all_rounds, bound) do
      :ok
    else
      # Granularidade de 1ms (não 5ms) para minimizar overhead artificial de
      # polling sobre o throughput medido — um SSP orientado a eventos real
      # não teria esse custo, mas 1ms já é pequeno frente às latências
      # simuladas (10-500ms).
      :timer.sleep(1)
      ssp_wait_gate(id, table, bound)
    end
  end

  # -------------------------------------------------------------------
  # Exp G — Regra de Mistura: AFL vs FedAsync sobre o mesmo MNIST non-IID
  #
  # Isola a diferença estrutural central entre o AFL e o FedAsync (Xie et
  # al., 2019): o AFL pondera cada update por seu tamanho de amostra $n_k$
  # (FedAvg incremental), enquanto o FedAsync usa mistura de peso FIXO
  # $\alpha_0$ atenuada por staleness. Mesmo protocolo do Experimento D
  # (1 nó aleatório por rodada, sem staleness simulada — isola a regra de
  # mistura, não o agendamento nem o tratamento de staleness do FedAsync),
  # mesma partição non-IID.
  #
  # Pareamento estrito: dentro de cada repetição, TODOS os braços (AFL e
  # cada valor de α₀) partem dos MESMOS pesos iniciais e veem a MESMA
  # sequência de nós sorteados por rodada — gerados uma única vez por
  # repetição e reutilizados. Sem isso, uma diferença de resultado entre
  # AFL e FedAsync poderia vir de sorte de inicialização/sorteio de nós,
  # não da regra de mistura em si (falha de uma versão anterior deste
  # experimento, corrigida aqui).
  # -------------------------------------------------------------------

  @fedasync_alpha0_values [0.1, 0.5, 0.9]

  def experiment_g_fedasync_convergence do
    banner("G", "Regra de mistura AFL vs FedAsync (α₀ ∈ #{inspect(@fedasync_alpha0_values)}) — MNIST non-IID")

    n_rounds = 150
    data = AFL.Data.load(train_size: 4_000, test_size: 800)
    {test_x, test_y} = data.test
    {train_x, train_y} = data.train

    rows =
      Enum.flat_map(1..@repetitions, fn rep ->
        progress("G", rep, @repetitions)

        # Mesma seed cobre a partição non-IID, os pesos iniciais
        # compartilhados por todos os braços, e a sequência de nós
        # sorteados por rodada — reprodutível entre execuções.
        seed = seed_rand!(:exp_g, rep)
        nodes = AFL.Data.partition_non_iid(train_x, train_y, @n_nodes, 2)
        shared_init = AFL.Model.init_params(seed)
        # Mesma sequência de nós sorteados para todos os braços desta repetição
        node_sequence = Enum.map(1..n_rounds, fn _ -> Enum.random(nodes) end)

        afl_rows = run_afl_convergence(shared_init, node_sequence, test_x, test_y, rep)

        fedasync_rows =
          Enum.flat_map(@fedasync_alpha0_values, fn alpha0 ->
            run_fedasync_convergence(shared_init, node_sequence, test_x, test_y, rep, alpha0)
          end)

        afl_rows ++ fedasync_rows
      end)

    export_csv(rows, "#{@results_dir}/exp_g_fedasync.csv")

    afl_final = rows |> Enum.filter(&(&1.method == :afl and &1.round == n_rounds))
    IO.puts("  → afl: acurácia final média (rodada #{n_rounds}) = #{Float.round(mean(Enum.map(afl_final, & &1.accuracy)), 3)}")

    for alpha0 <- @fedasync_alpha0_values do
      final = rows |> Enum.filter(&(&1.method == :fedasync and &1.alpha0 == alpha0 and &1.round == n_rounds))
      acc = final |> Enum.map(& &1.accuracy) |> mean()
      IO.puts("  → fedasync (α₀=#{alpha0}): acurácia final média (rodada #{n_rounds}) = #{Float.round(acc, 3)}")
    end

    rows
  end

  defp run_afl_convergence(init_params, node_sequence, test_x, test_y, rep) do
    AFL.Aggregator.reset(init_params)

    node_sequence
    |> Enum.with_index(1)
    |> Enum.map(fn {{x, y}, round_idx} ->
      global = AFL.Aggregator.get_model()
      updated = AFL.Model.local_train(global, x, y, epochs: 1, batch_size: 16, learning_rate: 0.3)
      AFL.Aggregator.update_sync(updated, Nx.axis_size(x, 0))

      metrics = AFL.Model.evaluate(AFL.Aggregator.get_model(), test_x, test_y)

      %{
        method: :afl,
        alpha0: nil,
        repetition: rep,
        round: round_idx,
        accuracy: Float.round(metrics.accuracy, 5),
        loss: Float.round(metrics.loss, 5)
      }
    end)
  end

  # Mesmo protocolo, mas a mistura é feita fora do Aggregator (que sempre
  # pondera por n_k) — mantém-se apenas os pesos como acumulador local,
  # combinados via AFL.Baselines.fedasync_merge/4 (peso fixo α₀, sem n_k).
  defp run_fedasync_convergence(init_params, node_sequence, test_x, test_y, rep, alpha0) do
    {rows, _final_weights} =
      node_sequence
      |> Enum.with_index(1)
      |> Enum.map_reduce(init_params, fn {{x, y}, round_idx}, weights ->
        updated = AFL.Model.local_train(weights, x, y, epochs: 1, batch_size: 16, learning_rate: 0.3)
        new_weights = AFL.Baselines.fedasync_merge(weights, updated, alpha0, 0)

        metrics = AFL.Model.evaluate(new_weights, test_x, test_y)

        row = %{
          method: :fedasync,
          alpha0: alpha0,
          repetition: rep,
          round: round_idx,
          accuracy: Float.round(metrics.accuracy, 5),
          loss: Float.round(metrics.loss, 5)
        }

        {row, new_weights}
      end)

    rows
  end

  # -------------------------------------------------------------------
  # Exp H — Caracterização de Resiliência via Injeção de Falhas
  #
  # Contribuição central após o pivô da tese: quantificar formalmente as
  # garantias de recuperação da árvore de supervisão do BEAM — e um gap
  # real descoberto no processo: o EdgeNode não estava em nenhuma árvore
  # de supervisão, e seu ring buffer ETS morria com o processo em caso de
  # crash (ver AFL.BufferKeeper e AFL.EdgeNodeSupervisor). H1 mede a perda
  # de gradientes sob crash do EdgeNode, comparando o mecanismo ORIGINAL
  # (sem herdeiro) contra o CORRIGIDO (com herdeiro + supervisão). H2 mede
  # as distribuições de tempo de recuperação sob crash do Aggregator e do
  # EdgeNode (já corrigido). H3 mede um gap ainda mais grave, descoberto
  # na revisão adversarial deste trabalho: o próprio Aggregator perdia o
  # MODELO GLOBAL INTEIRO (pesos, versão, total de amostras) a cada crash
  # --- o supervisor reiniciava o processo rapidamente, mas sempre a
  # partir de pesos iniciais estáticos, destruindo todo o progresso de
  # treinamento. Corrigido via AFL.ModelKeeper (mesma técnica de herdeiro
  # ETS do AFL.BufferKeeper, aplicada ao estado do Aggregator).
  # -------------------------------------------------------------------

  @h_trials 20
  @h_buffer_entries 3
  @h_training_rounds 5

  def experiment_h_resilience do
    banner("H", "Resiliência — perda sob crash (gradientes, modelo) e tempo de recuperação")

    loss_rows = experiment_h1_data_loss()
    recovery_rows = experiment_h2_recovery_time()
    model_loss_rows = experiment_h3_model_state_loss()

    %{loss: loss_rows, recovery: recovery_rows, model_loss: model_loss_rows}
  end

  # -------------------------------------------------------------------
  # Exp R4 — Falha Concorrente: EdgeNode e Aggregator caem juntos
  #
  # Os Experimentos R1-R3 testam UM processo falhando por vez. Isso deixa
  # uma pergunta real em aberto: AFL.BufferKeeper e AFL.ModelKeeper são
  # processos independentes, com tabelas ETS independentes — mas será que
  # ambos os mecanismos de recuperação seguem funcionando corretamente
  # quando os DOIS processos que protegem (EdgeNode e Aggregator) morrem
  # na mesma janela de tempo, não sequencialmente? Testa-se aqui: treina-se
  # o Aggregator, bufferiza-se gradientes no EdgeNode (já desconectado), e
  # então mata-se os dois processos em sucessão imediata (sem aguardar
  # nenhuma recuperação entre as duas mortes) — medindo se ambos os estados
  # sobrevivem de forma independente sob esse estresse concorrente.
  # -------------------------------------------------------------------

  def experiment_r4_concurrent_crash do
    banner("R4", "Falha concorrente — EdgeNode e Aggregator crasham juntos")

    rows =
      Enum.map(1..@h_trials, fn trial ->
        progress("R4", trial, @h_trials)
        {buffer_lost, version_lost} = simulate_concurrent_crash()

        %{
          trial: trial,
          buffer_entries_written: @h_buffer_entries,
          buffer_entries_lost: buffer_lost,
          training_rounds: @h_training_rounds,
          rounds_lost: version_lost
        }
      end)

    export_csv(rows, "#{@results_dir}/exp_r4_concurrent_crash.csv")

    total_buf_lost = rows |> Enum.map(& &1.buffer_entries_lost) |> Enum.sum()
    total_buf_written = rows |> Enum.map(& &1.buffer_entries_written) |> Enum.sum()
    total_rounds_lost = rows |> Enum.map(& &1.rounds_lost) |> Enum.sum()
    total_rounds_trained = rows |> Enum.map(& &1.training_rounds) |> Enum.sum()

    IO.puts(
      "  → Buffer: #{total_buf_lost}/#{total_buf_written} gradientes perdidos sob falha concorrente"
    )

    IO.puts(
      "  → Modelo: #{total_rounds_lost}/#{total_rounds_trained} rodadas de treino perdidas sob falha concorrente"
    )

    rows
  end

  # Treina o Aggregator, desconecta e bufferiza gradientes no EdgeNode, e
  # então mata AMBOS os processos em sucessão imediata (sem sincronizar
  # nenhuma recuperação entre as duas mortes) — mede a perda de cada
  # mecanismo de forma independente sob essa concorrência.
  defp simulate_concurrent_crash do
    AFL.Aggregator.reset(MockML.initial_weights())
    Enum.each(1..@h_training_rounds, fn _ -> AFL.Aggregator.update_sync(Nx.broadcast(1.0, {10}), 100) end)
    version_before = AFL.Aggregator.get_version()

    {:ok, _} = AFL.EdgeNodeSupervisor.start_edge_node(:r4_probe)
    Process.sleep(50)
    kill_aggregator_and_wait()

    Enum.each(1..@h_buffer_entries, fn _ -> :gen_statem.cast(AFL.EdgeNode, :train_and_send) end)
    :sys.get_state(AFL.EdgeNode)
    buffer_before = :ets.info(:edge_buffer, :size)

    # Neste ponto o Aggregator já morreu uma vez (para forçar :disconnected)
    # e o supervisor já o reiniciou — pega o pid ATUAL de cada processo e
    # mata os dois em sucessão imediata, sem aguardar nada entre as mortes.
    agg_pid = wait_for_pid(AFL.Aggregator, 2_000)
    edge_pid = Process.whereis(AFL.EdgeNode)
    agg_ref = Process.monitor(agg_pid)
    edge_ref = Process.monitor(edge_pid)

    Process.exit(agg_pid, :kill)
    Process.exit(edge_pid, :kill)

    receive do: ({:DOWN, ^agg_ref, :process, ^agg_pid, _} -> :ok)
    receive do: ({:DOWN, ^edge_ref, :process, ^edge_pid, _} -> :ok)

    new_agg = wait_for_new_pid(AFL.Aggregator, agg_pid, 2_000)
    new_edge = wait_for_new_pid(AFL.EdgeNode, edge_pid, 2_000)
    Process.sleep(50)

    version_after = if new_agg, do: AFL.Aggregator.get_version(), else: 0
    buffer_after = if new_edge, do: :ets.info(:edge_buffer, :size), else: 0

    version_lost = max(version_before - version_after, 0)
    buffer_lost = max(buffer_before - buffer_after, 0)

    AFL.EdgeNodeSupervisor.stop_edge_node()
    {buffer_lost, version_lost}
  end

  # -------------------------------------------------------------------
  # Exp R5 — Crash do Dono sob Posse Invertida
  #
  # Achado original (versão anterior deste experimento): o `:heir` de uma
  # tabela ETS é vinculado ao PID do processo herdeiro NO MOMENTO da
  # criação da tabela; se esse herdeiro (AFL.BufferKeeper) morre e é
  # reiniciado, o vínculo antigo fica órfão — matar o dono (EdgeNode) em
  # seguida destruía a tabela sem ninguém para recebê-la (100% de perda).
  # Encadear um segundo herdeiro não fecharia essa janela — apenas a
  # deslocaria um nível, pela mesma coincidência de timing.
  #
  # Correção estrutural aplicada: posse invertida. AFL.BufferKeeper e
  # AFL.ModelKeeper agora possuem suas tabelas PERMANENTEMENTE (nunca as
  # repassam via `:ets.give_away/3`), com zero lógica de domínio — o
  # EdgeNode e o Aggregator apenas escrevem nelas pelo nome. Isso elimina
  # por completo o cenário original: matar o worker nunca mais toca a
  # tabela, porque o worker nunca a possuiu. O que resta a testar é o
  # cenário novo, mais difícil: e se o próprio DONO morrer? Testa-se aqui
  # exatamente isso — para o buffer (sem persistência em disco, único
  # recurso é a árvore `:rest_for_one`) e para o modelo (com checkpoint em
  # disco no AFL.ModelKeeper, Seção~\ref{sec:r5}) — para medir se a
  # escalada de camada de persistência de fato fecha o gap onde ele mais
  # importa (o modelo global), e caracterizar honestamente o que ainda não
  # fecha (o buffer, perda ainda esperada sob esse cenário raro e
  # determinístico, não mais uma janela de corrida silenciosa).
  # -------------------------------------------------------------------

  def experiment_r5_heir_crash_race do
    banner("R5", "Crash do dono sob posse invertida — buffer (residual) vs. modelo (checkpoint em disco)")

    rows =
      Enum.flat_map(1..@h_trials, fn trial ->
        progress("R5", trial, @h_trials)

        buffer_lost = simulate_buffer_owner_crash(@h_buffer_entries)
        rounds_lost = simulate_model_owner_crash(@h_training_rounds)

        [
          %{trial: trial, scenario: :buffer_dono_morto, entries_written: @h_buffer_entries, entries_lost: buffer_lost},
          %{trial: trial, scenario: :modelo_dono_morto, entries_written: @h_training_rounds, entries_lost: rounds_lost}
        ]
      end)

    export_csv(rows, "#{@results_dir}/exp_r5_heir_crash.csv")

    for scenario <- [:buffer_dono_morto, :modelo_dono_morto] do
      grp = Enum.filter(rows, &(&1.scenario == scenario))
      total_lost = grp |> Enum.map(& &1.entries_lost) |> Enum.sum()
      total_written = grp |> Enum.map(& &1.entries_written) |> Enum.sum()
      IO.puts("  → #{scenario}: #{total_lost}/#{total_written} perdidos em #{@h_trials} crashes")
    end

    rows
  end

  # Mata o AFL.BufferKeeper (dono permanente do buffer, sem persistência em
  # disco) — mede a perda residual esperada: a tabela morre com o dono, e
  # o :rest_for_one derruba e reinicia o EdgeNode em cascata de forma
  # consistente (sem estado inválido), mas sem recuperar o conteúdo.
  defp simulate_buffer_owner_crash(n_entries) do
    {:ok, _} = AFL.EdgeNodeSupervisor.start_edge_node(:r5_probe)
    Process.sleep(50)
    kill_aggregator_and_wait()

    Enum.each(1..n_entries, fn _ -> :gen_statem.cast(AFL.EdgeNode, :train_and_send) end)
    :sys.get_state(AFL.EdgeNode)
    before_crash = :ets.info(:edge_buffer, :size)

    bk_pid = Process.whereis(AFL.BufferKeeper)
    bk_ref = Process.monitor(bk_pid)
    Process.exit(bk_pid, :kill)
    receive do: ({:DOWN, ^bk_ref, :process, ^bk_pid, _} -> :ok)

    new_bk = wait_for_new_pid(AFL.BufferKeeper, bk_pid, 2_000)
    Process.sleep(50)

    recovered = if new_bk, do: :ets.info(:edge_buffer, :size), else: 0
    lost = max(before_crash - recovered, 0)

    AFL.EdgeNodeSupervisor.stop_edge_node()
    lost
  end

  # Mata o AFL.ModelKeeper (dono permanente do estado do modelo) — mede se
  # o checkpoint em disco (escrita atômica via rename, Seção~\ref{sec:r5})
  # fecha o gap: o novo AFL.ModelKeeper relê o arquivo no próprio init/1, e
  # o Aggregator (reiniciado em cascata pelo :rest_for_one) recupera desse
  # snapshot em vez de partir dos pesos iniciais estáticos.
  defp simulate_model_owner_crash(n_rounds) do
    AFL.Aggregator.reset(MockML.initial_weights())
    Enum.each(1..n_rounds, fn _ -> AFL.Aggregator.update_sync(Nx.broadcast(1.0, {10}), 100) end)
    # Aguarda o checkpoint assíncrono em disco da última rodada persistir
    # antes de matar o dono — sem isso, mediríamos o atraso do I/O, não o
    # gap estrutural.
    Process.sleep(100)
    version_before = AFL.Aggregator.get_version()

    agg_pid = wait_for_pid(AFL.Aggregator, 2_000)
    mk_pid = Process.whereis(AFL.ModelKeeper)
    mk_ref = Process.monitor(mk_pid)
    Process.exit(mk_pid, :kill)
    receive do: ({:DOWN, ^mk_ref, :process, ^mk_pid, _} -> :ok)

    new_agg = wait_for_new_pid(AFL.Aggregator, agg_pid, 2_000)
    Process.sleep(50)

    version_after = if new_agg, do: AFL.Aggregator.get_version(), else: 0
    max(version_before - version_after, 0)
  end

  defp experiment_h1_data_loss do
    rows =
      Enum.flat_map(1..@h_trials, fn trial ->
        progress("H1", trial, @h_trials)

        loss_without = simulate_crash_without_heir(@h_buffer_entries)
        loss_with = simulate_crash_with_heir(@h_buffer_entries)

        [
          %{trial: trial, mechanism: :sem_heir, entries_written: @h_buffer_entries, entries_lost: loss_without},
          %{trial: trial, mechanism: :com_heir, entries_written: @h_buffer_entries, entries_lost: loss_with}
        ]
      end)

    export_csv(rows, "#{@results_dir}/exp_h1_data_loss.csv")

    for mechanism <- [:sem_heir, :com_heir] do
      grp = Enum.filter(rows, &(&1.mechanism == mechanism))
      total_lost = grp |> Enum.map(& &1.entries_lost) |> Enum.sum()
      total_written = grp |> Enum.map(& &1.entries_written) |> Enum.sum()
      IO.puts("  → #{mechanism}: #{total_lost}/#{total_written} gradientes perdidos em #{@h_trials} crashes")
    end

    rows
  end

  # Reproduz o design ORIGINAL: uma tabela ETS sem :heir — dono morto,
  # tabela destruída junto, incondicionalmente.
  defp simulate_crash_without_heir(n_entries) do
    parent = self()

    owner =
      spawn(fn ->
        table = :ets.new(:h_no_heir_probe, [:set, :private])
        Enum.each(1..n_entries, fn i -> :ets.insert(table, {i, :gradient}) end)
        send(parent, {:table, table})

        receive do
          :stop -> :ok
        end
      end)

    table = receive(do: ({:table, t} -> t))
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^owner, _} -> :ok))
    Process.sleep(5)

    case :ets.info(table) do
      :undefined -> n_entries
      _ -> 0
    end
  end

  # Reproduz o design CORRIGIDO usando o caminho de produção real (não uma
  # simulação simplificada): EdgeNode supervisionado por
  # AFL.EdgeNodeSupervisor, ring buffer com herdeiro AFL.BufferKeeper.
  defp simulate_crash_with_heir(n_entries) do
    {:ok, _} = AFL.EdgeNodeSupervisor.start_edge_node(:h_probe)
    Process.sleep(50)

    # Força :disconnected de forma determinística — mata o Aggregator e
    # aguarda o :DOWN monitorado propagar, evitando corrida com o restart
    # automático do supervisor (que poderia religar antes do EdgeNode notar).
    kill_aggregator_and_wait()

    Enum.each(1..n_entries, fn _ -> :gen_statem.cast(AFL.EdgeNode, :train_and_send) end)
    :sys.get_state(AFL.EdgeNode)

    before_crash = :ets.info(:edge_buffer, :size)

    old_pid = Process.whereis(AFL.EdgeNode)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^old_pid, _} -> :ok))

    new_pid = wait_for_new_pid(AFL.EdgeNode, old_pid, 2_000)
    Process.sleep(50)

    recovered = if new_pid, do: :ets.info(:edge_buffer, :size), else: 0
    lost = max(before_crash - recovered, 0)

    AFL.EdgeNodeSupervisor.stop_edge_node()
    lost
  end

  defp experiment_h2_recovery_time do
    agg_times =
      Enum.map(1..@h_trials, fn trial ->
        progress("H2a", trial, @h_trials)
        %{trial: trial, target: :aggregator, recovery_ms: measure_recovery_time(AFL.Aggregator)}
      end)

    {:ok, _} = AFL.EdgeNodeSupervisor.start_edge_node(:h_recovery_probe)
    Process.sleep(50)

    edge_times =
      Enum.map(1..@h_trials, fn trial ->
        progress("H2b", trial, @h_trials)
        %{trial: trial, target: :edge_node, recovery_ms: measure_recovery_time(AFL.EdgeNode)}
      end)

    AFL.EdgeNodeSupervisor.stop_edge_node()

    rows = agg_times ++ edge_times
    export_csv(rows, "#{@results_dir}/exp_h2_recovery_time.csv")

    for target <- [:aggregator, :edge_node] do
      grp = rows |> Enum.filter(&(&1.target == target)) |> Enum.map(& &1.recovery_ms) |> Enum.sort()

      IO.puts(
        "  → #{target}: recuperação média = #{Float.round(mean(grp), 1)}ms | " <>
          "p50 = #{Enum.at(grp, div(length(grp), 2))}ms | max = #{List.last(grp)}ms"
      )
    end

    rows
  end

  defp experiment_h3_model_state_loss do
    rows =
      Enum.flat_map(1..@h_trials, fn trial ->
        progress("H3", trial, @h_trials)

        version_lost_without = simulate_aggregator_crash_without_keeper()
        version_lost_with = simulate_aggregator_crash_with_keeper()

        [
          %{trial: trial, mechanism: :sem_keeper, rounds_trained: @h_training_rounds, rounds_lost: version_lost_without},
          %{trial: trial, mechanism: :com_keeper, rounds_trained: @h_training_rounds, rounds_lost: version_lost_with}
        ]
      end)

    export_csv(rows, "#{@results_dir}/exp_h3_model_loss.csv")

    for mechanism <- [:sem_keeper, :com_keeper] do
      grp = Enum.filter(rows, &(&1.mechanism == mechanism))
      total_lost = grp |> Enum.map(& &1.rounds_lost) |> Enum.sum()
      total_trained = grp |> Enum.map(& &1.rounds_trained) |> Enum.sum()
      IO.puts("  → #{mechanism}: #{total_lost}/#{total_trained} rodadas de treino perdidas em #{@h_trials} crashes do Aggregator")
    end

    rows
  end

  # Reproduz o design ORIGINAL do AFL.Aggregator.init/1: reconstrói sempre
  # a partir de pesos iniciais estáticos, incondicionalmente --- não é o
  # caminho de produção atual (já corrigido por AFL.ModelKeeper), mas o
  # comportamento exato de uma versão anterior deste trabalho, reproduzido
  # analiticamente (é determinístico: descarta 100% do progresso sempre).
  # Reproduz empiricamente (não apenas por aritmética) o design ORIGINAL:
  # um processo simples, iniciado com um argumento estático fixo --- como
  # o child_spec original do Aggregator ({AFL.Aggregator, initial_weights}),
  # que nunca consulta o estado anterior. Treina-se por rounds reais via
  # troca de mensagens, mata-se o processo de verdade, e "reinicia-se" ao
  # chamar a MESMA função com o MESMO argumento estático --- o mecanismo
  # exato do bug original, não uma simulação hipotética.
  defp simulate_aggregator_crash_without_keeper do
    static_initial_version = 0

    owner = spawn(fn -> old_style_aggregator_loop(static_initial_version) end)
    Enum.each(1..@h_training_rounds, fn _ -> send(owner, :train) end)
    send(owner, {:report, self()})
    version_before = receive(do: ({:version, v} -> v))

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^owner, _} -> :ok))

    restarted = spawn(fn -> old_style_aggregator_loop(static_initial_version) end)
    send(restarted, {:report, self()})
    version_after = receive(do: ({:version, v} -> v))
    Process.exit(restarted, :kill)

    version_before - version_after
  end

  defp old_style_aggregator_loop(version) do
    receive do
      :train -> old_style_aggregator_loop(version + 1)
      {:report, pid} -> send(pid, {:version, version})
    end
  end

  # Usa o caminho de produção real (corrigido): treina o Aggregator,
  # mata o processo, aguarda o supervisor reiniciá-lo, e mede quanto do
  # progresso (rodadas = versão) sobrevive.
  defp simulate_aggregator_crash_with_keeper do
    AFL.Aggregator.reset(MockML.initial_weights())
    Enum.each(1..@h_training_rounds, fn _ -> AFL.Aggregator.update_sync(Nx.broadcast(1.0, {10}), 100) end)
    version_before = AFL.Aggregator.get_version()

    old_pid = wait_for_pid(AFL.Aggregator, 2_000)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^old_pid, _} -> :ok))

    new_pid = wait_for_new_pid(AFL.Aggregator, old_pid, 2_000)
    Process.sleep(20)

    version_after = if new_pid, do: AFL.Aggregator.get_version(), else: 0
    max(version_before - version_after, 0)
  end

  defp measure_recovery_time(registered_name) do
    # Trials em rajada: o restart do trial anterior pode ainda não ter
    # terminado de registrar o nome quando o próximo trial começa.
    old_pid = wait_for_pid(registered_name, 2_000)
    start = System.monotonic_time(:microsecond)
    Process.exit(old_pid, :kill)
    new_pid = wait_for_new_pid_busy(registered_name, old_pid, start + 5_000_000)
    elapsed_us = System.monotonic_time(:microsecond) - start
    if new_pid, do: elapsed_us / 1000, else: 5_000.0
  end

  # Poll agressivo (sem sleep) para medir latência de restart real, não a
  # granularidade de um polling grosseiro — a restauração do supervisor é
  # rápida o suficiente para que um sleep de 10ms mascare toda a variância
  # real (confirmado empiricamente: toda amostra caía em exatamente 11ms).
  defp wait_for_new_pid_busy(name, old_pid, deadline_us) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:microsecond) < deadline_us do
          wait_for_new_pid_busy(name, old_pid, deadline_us)
        else
          nil
        end
    end
  end

  defp wait_for_pid(name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_pid_loop(name, deadline)
  end

  defp wait_for_pid_loop(name, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          wait_for_pid_loop(name, deadline)
        else
          raise "#{inspect(name)} never registered within timeout"
        end
    end
  end

  defp kill_aggregator_and_wait do
    case Process.whereis(AFL.Aggregator) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        receive(do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (500 -> :ok))
    end

    Process.sleep(200)
  end

  defp wait_for_new_pid(name, old_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_new_pid_loop(name, old_pid, deadline)
  end

  defp wait_for_new_pid_loop(name, old_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          wait_for_new_pid_loop(name, old_pid, deadline)
        else
          nil
        end
    end
  end

  # -------------------------------------------------------------------
  # Utilitários
  # -------------------------------------------------------------------

  # -------------------------------------------------------------------
  # Reprodutibilidade — seeds fixos e versionados
  #
  # Antes desta correção, a única fonte de aleatoriedade documentada era
  # `Enum.random`/`Enum.shuffle` no Experimento B (instabilidade de F entre
  # 8,4 e 109,1 em reexecuções, ver Seção VI do artigo) — mas havia uma
  # segunda fonte não documentada: `AFL.Model.init_params/0` delega a
  # `Axon.build/2` sem `:seed`, que usa `:erlang.system_time()` por padrão,
  # tornando os PESOS INICIAIS do modelo global diferentes a cada execução
  # em todo experimento que os usa (B, D, G). `seed_for/2` deriva uma seed
  # inteira determinística e estável (mesma entrada → mesma saída em
  # qualquer execução, hoje ou daqui a um ano) a partir do nome do
  # experimento e do índice da repetição — cobre tanto o `:rand` do Erlang
  # (Enum.random/Enum.shuffle) quanto o `Nx.Random` do Axon (pesos iniciais),
  # que são sistemas de PRNG independentes e não interferem entre si.
  # -------------------------------------------------------------------

  defp seed_for(tag, rep), do: :erlang.phash2({tag, rep})

  # Semeia o :rand do processo atual e retorna a mesma seed, para reuso em
  # chamadas a AFL.Model.init_params/1 dentro do mesmo escopo (rep).
  defp seed_rand!(tag, rep) do
    seed = seed_for(tag, rep)
    :rand.seed(:exsss, seed)
    seed
  end

  defp mean(list), do: Enum.sum(list) / length(list)

  defp banner(id, title) do
    IO.puts("┌─ Experimento #{id}: #{title}")
  end

  defp progress(_id, rep, total) do
    bar = String.duplicate("█", rep) <> String.duplicate("░", total - rep)
    IO.write("\r  [#{bar}] #{rep}/#{total}")
    if rep == total, do: IO.puts("")
  end

  defp export_csv([], path), do: IO.puts("  ⚠ Sem dados para #{path}")

  defp export_csv([first | _] = rows, path) do
    File.mkdir_p!(Path.dirname(path))
    headers = first |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.join(",")

    body =
      Enum.map_join(rows, "\n", fn row ->
        row |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(",")
      end)

    File.write!(path, headers <> "\n" <> body)
    IO.puts("  ✓ #{path} (#{length(rows)} linhas)")
  end
end
