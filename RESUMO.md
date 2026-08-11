# Resumo pra automação de posts (LinkedIn)

Este arquivo é a fonte que o automatizador de LinkedIn
(`/Users/victor/Documents/dev/linkedin-post-automate`) lê pra gerar posts sobre este
paper. Mantenha atualizado se o paper mudar.

**Título**: Resiliência Estrutural via Árvores de Supervisão para Aprendizado Federado
Assíncrono em Edge Computing: Caracterização Empírica sob Injeção de Falhas

**Autor/Fonte**: Victor Longchamps, sem filiação institucional (paper
próprio, implementação em `lib/`, código-fonte LaTeX em `artigo/main.tex`
deste repositório)

## Fatos-chave

- Problema: sistemas de FL para Edge Computing são comumente descritos como
  "resilientes" só por rodarem sobre runtimes com tolerância a falhas nativa
  (BEAM/OTP, atores, "let-it-crash") — mas essa afirmação raramente é verificada
  empiricamente, apenas assumida por inspeção de código.
- Resultado central (achado principal do trabalho): submeter essa suposição a
  injeção de falhas sistemática revelou que ela era **parcialmente falsa**, em dois
  componentes distintos do próprio sistema (AFL). O EdgeNode não estava em nenhuma
  árvore de supervisão — seu *ring buffer* ETS morria junto com o processo em caso de
  *crash*, perdendo **100% dos gradientes bufferizados** (60/60 sob 20 *crashes*
  injetados). Mais grave, descoberto numa segunda rodada de revisão adversarial: o
  Aggregator — o único ponto de agregação do sistema — era corretamente reiniciado
  pelo supervisor, mas seu *estado* não; **100% do progresso de treinamento era
  destruído** a cada falha (100/100 rodadas sob 20 *crashes* injetados), reiniciando
  sempre a partir de pesos estáticos, como se nenhum treinamento tivesse ocorrido.
- Correção: os dois gaps foram corrigidos com a mesma técnica — um supervisor
  dinâmico (`AFL.EdgeNodeSupervisor`) e herdeiros ETS (`AFL.BufferKeeper` para o
  buffer, `AFL.ModelKeeper` para o modelo) que preservam o estado através de
  reinícios. Sob as mesmas falhas injetadas após a correção: **0 gradientes e 0
  rodadas de treino perdidos**, com tempo de recuperação sub-milissegundo
  (mediana de 0,21 ms para o Aggregator, 0,09 ms para o EdgeNode) — mais de três
  ordens de grandeza mais rápido que orquestradores de contêiner convencionais.
- Validação complementar com ML real: o sistema também foi validado com treino
  federado real (MLP via Axon sobre partições non-IID do MNIST, não apenas tensores
  sintéticos), confirmando speedup de **15,89x** do AFL assíncrono sobre o FedAvg
  síncrono sob *stragglers* (158,2 vs 9,9 updates/s, p < 10⁻¹⁹), preservação de
  **95,8%** dos gradientes sob 50% de desconexão via *ring buffer*, e uma comparação
  empírica direta (não apenas qualitativa) com SSP e FedAsync que revela um
  resultado misto: o AFL supera uma barreira de staleness limitada inspirada em SSP
  em throughput sob *stragglers* extremos, mas perde para o FedAsync bem-ajustado em
  velocidade de convergência — uma limitação real da regra de agregação do AFL, não
  do seu mecanismo de resiliência.
- Implementação: construído em Elixir/BEAM (linguagem com tolerância a falhas
  nativa, modelo de atores), testado em hardware comum (Apple Silicon, sem GPU) —
  mas o próprio achado central do trabalho mostra que essa tolerância a falhas não é
  automática: só protege um processo que está de fato na árvore de supervisão e com
  seu estado devidamente herdado, não qualquer processo que "roda sobre BEAM/OTP".
- Relevância: Edge Computing e IA distribuída (IoT, dispositivos móveis, redes
  5G/rural) crescem rápido; a contribuição central deste trabalho não é uma nova
  fórmula de agregação, mas uma metodologia de **verificação** de resiliência via
  injeção de falhas sistemática (Chaos Engineering) — relevante para qualquer
  sistema distribuído que reivindique tolerância a falhas por herdar a plataforma,
  não por medir.
