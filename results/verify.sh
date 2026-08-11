#!/usr/bin/env bash
# Verificação automática pós-experimentos — substitui a caça manual
# grep-por-grep usada nas rodadas de revisão adversarial anteriores.
#
# Uso: results/verify.sh
# Deve ser rodado depois de `mix run -e 'AFL.Experiments.run_all()'` e de
# `python3 plot_figures.py` (dentro de results/), ou pelo `mix afl.verify`
# se preferir (ver lib/mix/tasks/afl_verify.ex, se existir).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIGO_DIR="$SCRIPT_DIR/../artigo"
FAIL=0

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$1"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$1"; FAIL=1; }

step "Arquivos de figura referenciados por \\includegraphics"
MISSING_FIGS=""
while IFS= read -r fig; do
  [ -f "$ARTIGO_DIR/$fig" ] || MISSING_FIGS="$MISSING_FIGS$fig\n"
done < <(grep -oE '\\includegraphics(\[[^]]*\])?\{[^}]+\}' "$ARTIGO_DIR/main.tex" | sed -E 's/.*\{([^}]+)\}/\1/')
if [ -n "$MISSING_FIGS" ]; then
  fail "arquivo(s) referenciado(s) por \\includegraphics mas ausente(s) em artigo/:"
  printf "$MISSING_FIGS" | sed 's/^/    /'
else
  ok "todo \\includegraphics referencia um arquivo presente"
fi

step "Macros que contêm \\times usadas fora de modo matemático"
# Tudo em python: extrair o VALOR de cada macro exige parênteses balanceados
# (o valor pode ter chaves aninhadas, ex. "14{,}62\times", que quebram
# qualquer regex de grep baseada em [^}]*), e checar "está dentro de
# $...$" exige contar quantos "$" não-escapados vieram antes na mesma
# linha (par = fora de modo matemático, ímpar = dentro) — uma heurística
# de "char anterior" já mascarou um bug real por checar o char errado.
BAD_USAGE=$(python3 -c "
import re

with open('stats_macros.tex') as f:
    macros_src = f.read()

math_only = set()
for m in re.finditer(r'\\\\newcommand\{(\\\\stat[A-Za-z]+)\}\{', macros_src):
    name, start = m.group(1), m.end()
    depth, i = 1, start
    while depth > 0 and i < len(macros_src):
        if macros_src[i] == '{': depth += 1
        elif macros_src[i] == '}': depth -= 1
        i += 1
    if '\\\\times' in macros_src[start:i-1]:
        math_only.add(name)

with open('main.tex') as f:
    lines = f.readlines()

bad = []
for lineno, line in enumerate(lines, 1):
    for name in math_only:
        for occ in re.finditer(re.escape(name) + r'(?![A-Za-z])', line):
            dollars_before = line[:occ.start()].count('\$') - line[:occ.start()].count(r'\\\$')
            if dollars_before % 2 == 0:
                bad.append(f'{lineno}: {name}')

for b in bad:
    print(b)
" 2>/dev/null || true)
if [ -n "$BAD_USAGE" ]; then
  fail "macro(s) com \\times usada(s) fora de \$...\$ (quebra a compilação):"
  echo "$BAD_USAGE" | sed 's/^/    /'
else
  ok "toda macro com \\times está corretamente envolta em \$...\$"
fi

step "Macros estatísticas"
if [ -f "$ARTIGO_DIR/stats_macros.tex" ]; then
  n=$(grep -c '^\\newcommand' "$ARTIGO_DIR/stats_macros.tex")
  ok "stats_macros.tex presente ($n macros)"
else
  fail "stats_macros.tex não encontrado — rode plot_figures.py primeiro"
fi

step "Compilação LaTeX"
cd "$ARTIGO_DIR" || exit 1
LOG=$(tectonic main.tex 2>&1)
if [ $? -ne 0 ]; then
  fail "tectonic falhou"
  echo "$LOG" | tail -20
else
  ok "tectonic compilou sem erro de saída"
fi

step "Erros de renderização/referência"
PATTERN='[Uu]ndefined control sequence|Missing character|[Uu]ndefined reference|[Mm]ultiply defined|LaTeX Warning: Reference .* undefined'
if echo "$LOG" | grep -qE "$PATTERN"; then
  fail "encontrados problemas de compilação:"
  echo "$LOG" | grep -E "$PATTERN"
else
  ok "nenhum undefined control sequence / missing character / referência quebrada"
fi

step "Macros referenciadas em main.tex vs definidas em stats_macros.tex"
used=$(grep -oE '\\stat[A-Za-z0-9]+' main.tex | sort -u | sed 's/^\\//')
defined=$(grep -oE '^\\newcommand\{\\stat[A-Za-z0-9]+' stats_macros.tex | sed 's/^\\newcommand{\\//' | sort -u)
missing=$(comm -23 <(echo "$used") <(echo "$defined"))
if [ -n "$missing" ]; then
  fail "macro(s) usada(s) em main.tex mas não definida(s) em stats_macros.tex:"
  echo "$missing" | sed 's/^/    /'
else
  ok "toda macro \\statXxx usada em main.tex está definida"
fi

step "Citações vs referencias.bib"
cited=$(grep -o '\\cite{[^}]*}' main.tex | sed 's/\\cite{//;s/}//' | tr ',' '\n' | sort -u)
bibkeys=$(grep -o '^@[a-z]*{[^,]*,' referencias.bib | sed 's/^@[a-z]*{//;s/,$//' | sort -u)
cited_missing=$(comm -23 <(echo "$cited") <(echo "$bibkeys"))
bib_unused=$(comm -13 <(echo "$cited") <(echo "$bibkeys"))
if [ -n "$cited_missing" ]; then
  fail "citado em main.tex mas ausente de referencias.bib:"
  echo "$cited_missing" | sed 's/^/    /'
else
  ok "toda \\cite{} tem entrada correspondente em referencias.bib"
fi
if [ -n "$bib_unused" ]; then
  fail "presente em referencias.bib mas nunca citado (considere remover):"
  echo "$bib_unused" | sed 's/^/    /'
else
  ok "nenhuma entrada de referencias.bib está sem uso"
fi

step "Nomes de macro com dígito (inválidos em \\newcommand)"
BAD_NAMES=$(grep -oE '^\\newcommand\{\\stat[A-Za-z0-9]+' stats_macros.tex 2>/dev/null | grep -E '[0-9]' || true)
if [ -n "$BAD_NAMES" ]; then
  fail "macro(s) com dígito no nome — \\newcommand exige letras apenas:"
  echo "$BAD_NAMES" | sed 's/^/    /'
else
  ok "nenhum nome de macro contém dígito"
fi

step "Caracteres Unicode não-seguros para as fontes do IEEEtran"
# Remove comentários (% até fim da linha) antes de checar — texto comentado
# nunca é tipografado, então em-dash ali não é um problema de renderização.
UNSAFE=$(sed -E 's/([^\\])%.*/\1/' main.tex | LC_ALL=en_US.UTF-8 grep -n $'[—–×]' || true)
if [ -n "$UNSAFE" ]; then
  fail "caracteres Unicode literais (em-dash/×) fora de comandos — trocar por ---/\\times"
  echo "$UNSAFE" | sed 's/^/    /'
else
  ok "nenhum em-dash/× literal encontrado"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32mTudo verde.\033[0m\n'
else
  printf '\033[1;31mFalhas encontradas acima — corrigir antes de prosseguir.\033[0m\n'
fi
exit "$FAIL"
