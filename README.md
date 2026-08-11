# AFL — Aprendizado Federado Assíncrono, testado contra falhas reais

**TL;DR para quem não é da área:** todo sistema distribuído moderno promete
"tolerância a falhas". Este projeto pega essa promessa e a testa de verdade —
matando processos de propósito, no meio da execução, e medindo o que
realmente sobrevive. O resultado: a promessa era **parcialmente falsa**, num
sistema que eu mesmo construí. Este repositório documenta os bugs
encontrados, as correções, e os dados por trás de tudo isso.

---

## O problema, em uma frase

Sistemas de aprendizado distribuído para Edge Computing costumam se dizer
"resilientes" só porque foram construídos sobre uma plataforma com
tolerância a falhas nativa (neste caso, Elixir/BEAM/OTP — o mesmo runtime
usado por WhatsApp e por boa parte da infraestrutura de telecom mundial).
Mas **"a plataforma é resiliente" não é o mesmo que "meu sistema, construído
sobre ela, é resiliente"** — e essa lacuna quase nunca é verificada, só
assumida.

## O que é o AFL

O **AFL** (*Asynchronous Federated Learning*) é um sistema de aprendizado
federado assíncrono: em vez de esperar todos os participantes ("nós de
borda") enviarem sua contribuição antes de avançar uma rodada de treino (o
jeito clássico, síncrono), cada nó envia sua atualização assim que estiver
pronto, e o servidor central ("Aggregator") a incorpora imediatamente. Isso
evita que o participante mais lento (um celular numa conexão ruim, um
sensor IoT no meio do campo) segure todo o sistema — o cenário típico de
Edge Computing.

Ele tem três peças de mecanismo:
1. **FedAvg incremental** ponderado por tamanho de amostra — a mesma
   matemática do FedAvg clássico (McMahan et al., 2017), só que aplicada
   update a update em vez de em lote.
2. **Penalidade de *staleness* hiperbólica** — atualizações que chegam
   atrasadas (calculadas sobre uma versão antiga do modelo) ainda são
   aceitas, mas com peso reduzido proporcionalmente ao atraso, em vez de
   simplesmente descartadas.
3. **Ring buffer local** — se um nó perde conexão com o servidor, ele
   continua treinando localmente e acumula as atualizações num buffer
   circular, sincronizando tudo quando a conexão volta.

Isso, por si só, já seria um projeto razoável de mestrado. Mas a pergunta
que motivou este trabalho foi outra: **essas três peças realmente resistem
a falhas de processo, ou só parecem resistir porque nunca foram testadas
contra uma de verdade?**

## A abordagem: Chaos Engineering

Em vez de confiar em inspeção de código ou em testes unitários pontuais, o
projeto aplica **Engenharia do Caos** (Basiri et al., *Chaos Engineering*,
IEEE Software, 2016) — a mesma disciplina usada por empresas como a Netflix
para validar sistemas em produção: **injetar falhas reais, de propósito, e
medir quantitativamente o antes e o depois**, em vez de argumentar que o
design "deveria" funcionar.

Na prática, isso significa: matar processos no meio da execução
(`Process.exit(pid, :kill)` — um sinal não-capturável, que não dá chance ao
processo de se despedir educadamente), sob condições controladas e
repetidas dezenas de vezes, medindo:
- Quantos dados (gradientes bufferizados, progresso de treino) sobrevivem?
- Quanto tempo leva para o sistema se recuperar?
- O que acontece sob combinações de falhas mais adversas (duas falhas ao
  mesmo tempo, uma falha durante a recuperação de outra)?

## O que foi encontrado

A suposição "roda sobre BEAM/OTP, então é resiliente" se revelou **apenas
parcialmente verdadeira**, em dois componentes distintos do próprio AFL:

| Onde | O que quebrava | Antes da correção | Depois |
|---|---|---|---|
| **EdgeNode** (nó de borda) | O processo não estava em nenhuma árvore de supervisão — seu buffer de gradientes morria junto com ele em caso de crash | **100% dos gradientes perdidos** (60/60, sob 20 crashes injetados) | **0%** |
| **Aggregator** (servidor) | O processo *era* reiniciado corretamente pelo supervisor — mas seu estado (pesos do modelo, progresso de treino) não | **100% do modelo global destruído** a cada crash (100/100 rodadas) | **0%** |

A correção usa a mesma técnica nos dois casos: um processo auxiliar
permanente (`AFL.BufferKeeper` / `AFL.ModelKeeper`) que herda o estado via
`:heir` do ETS (a tabela de memória do Erlang/Elixir) sempre que o processo
principal morre, devolvendo-o intacto para a próxima instância. O tempo de
recuperação, mesmo com essa correção, ficou abaixo de **1 milissegundo** —
mais de três ordens de grandeza mais rápido que reiniciar um container
Kubernetes, porque não há re-provisionamento de sistema operacional
envolvido, só a criação de um processo leve dentro de uma VM já em
execução.

**Um terceiro achado, honesto sobre seus próprios limites:** o mecanismo de
herdeiro (`:heir`) do ETS é vinculado a um PID específico *no momento em
que a tabela é criada* — se esse próprio herdeiro morrer e for reiniciado,
o vínculo antigo fica órfão, e uma falha subsequente do processo principal
volta a causar 100% de perda. Esse gap foi medido e confirmado. Em vez de
simplesmente reportá-lo como limitação, a versão mais recente do projeto
resolve isso de fato — não encadeando um segundo herdeiro (o que só move o
mesmo problema um nível acima), mas invertendo a posse: o processo
guardião passa a ser o dono **permanente** da tabela, com zero lógica de
negócio (logo, quase nenhuma chance de falhar por conta própria), e para o
estado mais crítico (o modelo global) a correção escala até um checkpoint
atômico em disco — fechando o gap por completo onde ele mais importava.
Veja a branch `paper/resilience-only` para os detalhes.

**Validação em rede real:** para garantir que a simulação de latência (via
`Process.sleep`, dentro de uma única VM) não estava escondendo nada, o
mesmo experimento de throughput foi reproduzido entre containers Docker
conectados por TCP/IP genuíno — o speedup medido bateu com o simulado
(mesma ordem de grandeza), confirmando que a simulação era representativa.

**Comparação honesta com a literatura:** o AFL foi comparado empiricamente
(não só qualitativamente) contra SSP (Ho et al., 2013) e FedAsync (Xie et
al., 2019) sob o mesmo protocolo. O resultado é **misto**, e é reportado
como tal: o AFL vence em throughput sob *stragglers* extremos, mas perde
para o FedAsync bem-ajustado em velocidade de convergência — uma limitação
real do seu passo de mistura, não do seu mecanismo de resiliência.

## Por que isso importa

A contribuição central deste trabalho **não é uma nova fórmula de
agregação** — é uma **metodologia de verificação**: submeter reivindicações
de resiliência a evidência quantitativa, via injeção de falhas sistemática,
em vez de aceitá-las por herança da plataforma escolhida. Isso é relevante
para qualquer sistema distribuído — de FL ou não — que cite seu runtime
("roda sobre Kubernetes", "roda sobre um framework de atores") como
justificativa de resiliência sem ter, de fato, medido processo por
processo.

## Arquitetura (visão rápida)

```
EdgeNode (:gen_statem)  <---->  Aggregator (GenServer)
     |                                |
     v                                v
AFL.BufferKeeper                AFL.ModelKeeper
(dono do buffer ETS,            (dono do estado ETS,
 sobrevive a crashes             sobrevive a crashes
 do EdgeNode)                    do Aggregator)
```

Implementado em **Elixir 1.19 / OTP 28**, usando **Nx** e **Axon** para as
partes de treino real (MLP sobre MNIST não-IID), rodando em hardware comum
(Apple Silicon, sem GPU) — a própria plataforma escolhida é parte do
argumento: se um gap de resiliência aparece mesmo aqui, ele não é exclusivo
de infraestrutura "mal feita".

## Como rodar

```bash
mix deps.get
mix test                              # suíte de testes (inclui os cenários de caos)
mix run -e "AFL.Experiments.run_all()" # roda todos os experimentos, gera CSVs em results/
```

Depois de rodar os experimentos:

```bash
cd results && python3 plot_figures.py  # gera figuras + artigo/stats_macros.tex
../results/verify.sh                   # checagem automática de consistência do paper
```

O paper completo (LaTeX) está em [`artigo/main.tex`](artigo/main.tex);
compila com [Tectonic](https://tectonic-typesetting.github.io/).

## Estrutura do repositório

- `lib/` — implementação Elixir (Aggregator, EdgeNode, BufferKeeper/
  ModelKeeper, experimentos)
- `test/` — suíte de testes, incluindo os cenários de injeção de falhas
- `results/` — CSVs dos experimentos, script de geração de figuras
  (`plot_figures.py`) e de verificação (`verify.sh`)
- `distributed_bench/` — benchmark em rede real (Docker + Erlang
  distribuído genuíno), independente da simulação principal
- `artigo/` — o paper em LaTeX, com pipeline de macros para eliminar
  números duplicados manualmente entre Abstract/Resultados/Conclusão

### Branches

- `main` — versão completa (mecanismo de agregação + resiliência)
- `paper/resilience-only` — versão focada exclusivamente na contribuição de
  resiliência/chaos engineering, com o gap do herdeiro corrigido de fato
  (posse invertida + checkpoint em disco)
- `paper/journal-planning` — plano (não implementado) do que faltaria para
  submeter essa linha de pesquisa a uma revista científica

## Referências principais

- McMahan et al. (2017), *Communication-Efficient Learning of Deep Networks
  from Decentralized Data* — introduz o FedAvg, base matemática do AFL.
- Ho et al. (2013), *More Effective Distributed ML via a Stale Synchronous
  Parallel Parameter Server* — o SSP, usado como baseline de comparação.
- Xie et al. (2019), *Asynchronous Federated Optimization* — o FedAsync,
  segundo baseline de comparação.
- Bonawitz et al. (2019), *Towards Federated Learning at Scale* — desafios
  de escala e falhas de dispositivo em FL de produção (Google).
- Shi et al. (2020), *Communication-Efficient Edge AI* — trade-offs de
  comunicação em FL sobre Edge Computing.
- **Basiri et al. (2016), *Chaos Engineering*, IEEE Software** — a
  metodologia central deste trabalho: injeção de falhas sistemática como
  prática de verificação, não só de teste.
- Dwork & Roth (2014), *The Algorithmic Foundations of Differential
  Privacy* — citado nas Limitações (DP não implementado nesta versão).

A lista completa, com entradas BibTeX, está em
[`artigo/referencias.bib`](artigo/referencias.bib).

## Autor

Victor Longchamps — victor.and.longchamps@gmail.com
