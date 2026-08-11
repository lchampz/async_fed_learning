# Validação em Rede Real (Fase 4 do plano de fechamento)

Repete a comparação assíncrono vs síncrono do Experimento A (ver
`artigo/main.tex`, Seção "Validação em Rede Real"), mas entre nós BEAM
genuinamente distribuídos — processos de sistema operacional separados, em
containers Docker isolados, conectados por rede TCP/IP real via bridge do
Docker — em vez de `Process.sleep` simulando latência dentro de uma única
VM.

Este benchmark é **autocontido**: não depende do projeto Mix principal
(sem Axon/EXLA), só de Elixir/OTP puro, para evitar o custo/risco de
compilar dependências nativas dentro de containers.

## Rodar

```bash
docker compose build
./run_repetitions.sh 10   # 10 repetições, casa com o Experimento A original
```

Resultado agregado em `results/exp_a_distributed.csv`, consumido por
`results/plot_figures.py` (na raiz do projeto) via caminho relativo.

## Como funciona

- `bench.exs`: script Elixir puro (sem projeto Mix). Um papel `aggregator`
  coordena `K` `edge`s conectados via Erlang distribuído
  (`Node.connect/1`, nomes curtos `--sname`, cookie compartilhado).
- Cada `edge` simula seu tempo de processamento LOCAL via `Process.sleep`
  (não o tempo de rede — esse é genuíno, medido pela transmissão real via
  `send/2` entre nós distintos).
- Fase assíncrona: cada edge envia updates independentemente por `T`
  segundos; aggregator conta.
- Fase síncrona: aggregator implementa uma barreira --- aguarda um `:ack`
  de TODOS os edges antes de iniciar a próxima rodada.
- `docker-compose.yml` define 5 edges com as mesmas latências do
  Experimento A original (`[10, 10, 20, 50, 500]` ms).

## Limitação conhecida

A rede aqui é a bridge interna do Docker no mesmo hospedeiro físico ---
latência de trânsito sub-milissegundo entre containers, não uma rede
geograficamente distribuída como um deploy real de Edge Computing veria.
O objetivo é validar que a pilha de rede real (TCP, serialização,
scheduling do SO) não muda a conclusão qualitativa do Experimento A, não
reproduzir latência de WAN.
