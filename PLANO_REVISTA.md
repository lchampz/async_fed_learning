# Plano — O que falta para uma revista conceituada

Baseado na versão `paper/resilience-only` (foco exclusivo em resiliência via
chaos engineering). Pergunta guia: **o que este trabalho precisaria ter ou
melhorar para ser competitivo numa revista conceituada** (ex.: IEEE TDSC,
IEEE TPDS, JPDC, Journal of Systems and Software/Elsevier, FGCS)?

Isto é um plano, não uma implementação — nenhuma dessas mudanças foi feita
nesta branch ainda.

## Diagnóstico honesto do estado atual

O que já está no nível de revista: rigor estatístico (Holm-Bonferroni),
pipeline anti-drift de macros, reprodutibilidade (seeds fixos, `verify.sh`),
achados negativos reportados sem filtro (R5), validação em rede real. O que
NÃO está: é uma dissertação de mestrado de autor único, sobre um único
sistema/plataforma, sem revisão sistemática da literatura de chaos
engineering aplicado a ML distribuído, e sem uma seção formal de "Threats to
Validity" (padrão em papers empíricos de sistemas/SE).

## Tier 1 — Bloqueadores reais (sem isso, rejeição provável)

1. **Busca de literatura para novidade.** Ainda não foi verificado se já
   existe trabalho publicado aplicando chaos engineering especificamente a
   sistemas de FL (ou a sistemas de atores/BEAM em geral). Isso precisa ser
   feito ANTES de qualquer submissão — se existir, o posicionamento de
   "diferencial" muda; se não existir, isso é o principal argumento de
   novidade e precisa estar explícito e defendido na Introdução/Related
   Work, não apenas implícito.
2. **Seção formal de "Threats to Validity".** A Seção de Limitações atual é
   boa mas informal. Revistas de sistemas/SE esperam a tríade padrão:
   validade interna (o experimento mede o que diz medir?), validade externa
   (generaliza para outros sistemas/plataformas?), validade de construto
   (as métricas — % de perda, tempo de recuperação — capturam o conceito de
   "resiliência" adequadamente?). Isso é reescrita/reorganização, não
   experimento novo — mas é obrigatório.
3. **Generalizar a contribuição além do BEAM.** Hoje o achado central
   (posse invertida > herdeiro encadeado) é apresentado como uma correção
   específica de um bug do AFL. Para revista, isso precisa ser elevado a
   **metodologia/checklist transferível**: um roteiro reutilizável para
   auditar reivindicações de resiliência em qualquer sistema construído
   sobre um runtime com supervisão nativa (atores, Kubernetes, Erlang/OTP,
   Akka) — não apenas "nós corrigimos um bug nosso". Isso é o que separa um
   relato de caso de uma contribuição científica.

## Tier 2 — Fortalece bastante, viável para autor solo

4. **Intervalos de confiança binomiais nos resultados de perda.** R1-R5
   reportam 0%/100% sobre n=20 \textit{trials} como estimativas pontuais.
   Um revisor de revista vai pedir IC (Wilson ou Clopper-Pearson) em vez de
   só a proporção — com n=20, um IC 95% em torno de "0%" ainda deixa uma
   cauda superior não-trivial que hoje não é comunicada. Mudança mecânica
   no `plot_figures.py`, sem experimento novo.
5. **Ampliar o repertório de falhas.** Hoje só falha = *crash* de processo.
   Falta ao menos uma segunda classe de falha realista de Edge Computing:
   partição de rede (processo vivo, inatingível — já citado como limitação,
   nunca testado) é a mais barata de implementar (usar `:net_kernel` /
   bloqueio de porta) e a que mais reforça a generalidade do achado
   (posse invertida não resolve partição — só resolve o processo estar
   morto; isso é, aliás, um resultado interessante por si só).
6. **Segundo sistema, mesmo que minúsculo, para a metodologia (não para o
   AFL).** Não precisa reimplementar o AFL noutra stack — mas aplicar o
   mesmo protocolo de injeção de falhas a um segundo sistema simples
   (ex.: um pipeline de agregação em Python com `multiprocessing` +
   checkpoint manual) e mostrar que o MESMO tipo de gap aparece lá
   (dono/herdeiro, ou equivalente) é a evidência mais direta de que a
   metodologia generaliza, não é uma peculiaridade do BEAM.

## Tier 3 — Melhora a forma, baixo custo

7. **Related Work sistemático**, não só qualitativo. Cobertura por busca
   estruturada (IEEE Xplore/ACM DL/Google Scholar, termos: "chaos
   engineering" + "federated learning" / "fault injection" + "actor model" /
   "resilience testing" + "distributed ML") com uma tabela comparativa
   (trabalho × tipo de falha testada × plataforma × metodologia).
8. **Artefato público com DOI** (Zenodo/Software Heritage) no momento da
   submissão — revistas de sistemas hoje frequentemente pedem ou premiam
   isso (badge de reprodutibilidade).
9. **Ajuste de formatação** para o template da revista-alvo (a maioria usa
   IEEE Transactions two-column, diferente do IEEEtran conference atual —
   mudança mecânica de classe LaTeX, não de conteúdo).
10. **Pré-print + feedback externo** antes da submissão formal (arXiv ou
    equivalente) — não é requisito da revista, mas reduz risco de rejeição
    por pontos que um leitor externo teria pego antes.

## Not recomendado agora

Reintroduzir a metade de agregação (H1-H5, comparação com SSP/FedAsync)
NÃO deveria voltar para esta frente — essa é precisamente a parte mais
fraca segundo a avaliação anterior (resultado misto, sem vantagem clara),
e diluiria o argumento de novidade do ângulo de resiliência. Se algum dia
for publicada, deveria ser um paper separado, focado em algoritmo de
agregação, não misturado com a contribuição de metodologia de verificação.

## Ordem sugerida

Tier 1 primeiro (bloqueadores) → item 5 (partição de rede, barato e reforça
Tier 1.3) → item 4 (IC binomial, mecânico) → item 6 (segundo sistema, o mais
caro mas o de maior retorno para "revista conceituada" especificamente) →
Tier 3 por último, próximo da submissão real.

## Escolha de venue (a decidir com o orientador)

Mais provável de aceitar o ângulo metodológico (chaos engineering como
contribuição, não um algoritmo novo): **IEEE TDSC** (Dependable and Secure
Computing — resiliência é o núcleo do venue) ou **Journal of Systems and
Software** (Elsevier — aceita bem estudos empíricos de engenharia de
sistemas). **IEEE TPDS**/**JPDC** são alternativas se o ângulo for reforçado
mais para o lado de sistemas distribuídos/paralelos do que dependabilidade.
