#!/usr/bin/env bash
# Roda o benchmark distribuído N vezes (por padrão 10, para casar com o
# número de repetições do Experimento A original) e agrega os resultados
# em results/exp_a_distributed.csv.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

N="${1:-10}"
mkdir -p results
rm -f results/distributed_bench_result_*.json

for i in $(seq 1 "$N"); do
  echo "=== Repetição $i/$N ==="
  REP="$i" docker compose up --abort-on-container-exit >/tmp/dbench_rep_${i}.log 2>&1
  docker compose down >/dev/null 2>&1
done

echo "repetition,k,duration_ms,async_updates_per_s,sync_updates_per_s,speedup" > results/exp_a_distributed.csv
for i in $(seq 1 "$N"); do
  f="results/distributed_bench_result_${i}.json"
  if [ -f "$f" ]; then
    python3 -c "
import json
d = json.load(open('$f'))
print(f\"$i,{d['k']},{d['duration_ms']},{d['async_updates_per_s']},{d['sync_updates_per_s']},{d['speedup']}\")
" >> results/exp_a_distributed.csv
  else
    echo "AVISO: resultado da repetição $i não encontrado ($f)" >&2
  fi
done

echo "✓ results/exp_a_distributed.csv"
cat results/exp_a_distributed.csv
