"""
Geração de figuras para o artigo científico AFL.
Gera 6 figuras em formato PDF (qualidade publicação) e PNG (preview).

Exp. B e D usam treino federado real sobre MNIST non-IID (ver
lib/experiments.ex) — não mais tensores sintéticos.
"""

import math
import pandas as pd
import numpy as np
import matplotlib
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import scipy.stats as stats
import warnings
warnings.filterwarnings("ignore")

# ── Estilo publicação ────────────────────────────────────────────────────────
matplotlib.rcParams.update({
    "font.family":      "serif",
    "font.size":        11,
    "axes.titlesize":   12,
    "axes.labelsize":   11,
    "axes.spines.top":  False,
    "axes.spines.right":False,
    "legend.framealpha":0.9,
    "lines.linewidth":  2,
    "figure.dpi":       150,
})

PALETTE = {
    "async":           "#2563EB",   # azul
    "sync":            "#DC2626",   # vermelho
    "hyperbolic":      "#7C3AED",   # roxo
    "exponential_05":  "#059669",   # verde
    "exponential_01":  "#D97706",   # laranja
    "no_penalty":      "#6B7280",   # cinza
    "buffer":          "#0891B2",   # ciano
    "converge":        "#16A34A",   # verde escuro
    "shade":           "#BFDBFE",   # azul claro (fill)
}

BUFFER_COLORS = {
    0:           "#DC2626",
    5:           "#0891B2",
    20:          "#7C3AED",
    "unbounded": "#16A34A",
}

def ci95(series):
    """Intervalo de confiança 95% via t-distribution."""
    n = len(series)
    if n < 2:
        return 0.0
    se = series.std(ddof=1) / np.sqrt(n)
    return se * stats.t.ppf(0.975, df=n - 1)

def cohens_d(a, b):
    a, b = np.asarray(a, dtype=float), np.asarray(b, dtype=float)
    pooled_std = np.sqrt(((a.std(ddof=1) ** 2) + (b.std(ddof=1) ** 2)) / 2)
    return (a.mean() - b.mean()) / pooled_std if pooled_std > 0 else float("nan")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 1 — Throughput Async vs Sync (inalterado — não usa ML real,
# mede especificamente o efeito de escalonamento sob stragglers)
# ════════════════════════════════════════════════════════════════════════════
df_a = pd.read_csv("exp_a_throughput.csv")

fig, axes = plt.subplots(1, 2, figsize=(12, 4.5))
fig.suptitle(
    "Experimento A — Throughput: FedAvg Assíncrono vs Síncrono\n"
    r"(K=5 nós com latências $\ell = [10, 10, 20, 50, 500]$ ms, $T=5$ s)",
    fontsize=11, y=1.02
)

ax = axes[0]
agg = df_a.drop_duplicates("repetition")
reps = agg["repetition"]
async_ups = agg["async_updates_per_s"]
sync_ups  = agg["sync_updates_per_s"]

ax.bar(reps - 0.2, async_ups, width=0.4, label="AFL Assíncrono",
       color=PALETTE["async"], alpha=0.85)
ax.bar(reps + 0.2, sync_ups,  width=0.4, label="FedAvg Síncrono",
       color=PALETTE["sync"],  alpha=0.85)

ax.axhline(async_ups.mean(), color=PALETTE["async"], ls="--", lw=1.2, alpha=0.7)
ax.axhline(sync_ups.mean(),  color=PALETTE["sync"],  ls="--", lw=1.2, alpha=0.7)

ax.set_xlabel("Repetição")
ax.set_ylabel("Updates / segundo")
ax.set_title("Throughput por repetição")
ax.legend()
ax.set_xticks(reps)

ax2 = axes[1]
speedups = agg["speedup"]

bp = ax2.boxplot(speedups, patch_artist=True, widths=0.5,
                 boxprops=dict(facecolor=PALETTE["shade"], color=PALETTE["async"]),
                 whiskerprops=dict(color=PALETTE["async"]),
                 capprops=dict(color=PALETTE["async"]),
                 medianprops=dict(color=PALETTE["sync"], linewidth=2))

ax2.scatter([1] * len(speedups), speedups, color=PALETTE["async"],
            alpha=0.6, zorder=5, s=40, label="Observações")

t_stat, p_val = stats.ttest_1samp(speedups, 1.0)
sig = "***" if p_val < 0.001 else "**" if p_val < 0.01 else "*" if p_val < 0.05 else "ns"

ax2.set_ylabel("Speedup (Async / Sync)")
ax2.set_title(
    f"Speedup médio: {speedups.mean():.2f}×\n"
    f"t={t_stat:.2f}, p={p_val:.4f} {sig}"
)
ax2.set_xticks([])
ax2.axhline(1.0, color="black", ls=":", lw=1, label="Sem ganho (1×)")
ax2.legend(fontsize=9)

plt.tight_layout()
plt.savefig("fig1_throughput.pdf", bbox_inches="tight")
plt.savefig("fig1_throughput.png", bbox_inches="tight")
plt.close()
print("✓ fig1_throughput.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 2 — Staleness: Bias real por Função de Penalidade (treino MNIST)
# ════════════════════════════════════════════════════════════════════════════
df_b = pd.read_csv("exp_b_staleness.csv")

fn_labels = {
    "hyperbolic":     r"Hiperbólica $\frac{1}{1+\delta}$",
    "exponential_05": r"Exponencial $e^{-0.5\delta}$",
    "exponential_01": r"Exponencial $e^{-0.1\delta}$",
    "no_penalty":     "Sem penalidade",
}
fn_colors = {k: PALETTE[k] for k in fn_labels}

fig, axes = plt.subplots(1, 2, figsize=(13, 4.5))
fig.suptitle(
    "Experimento B — Staleness: Impacto Real de Updates Atrasados (MNIST non-IID)\n"
    r"Bias de loss: $\Delta\mathcal{L} = \mathcal{L}_{\text{depois}} - \mathcal{L}_{\text{antes}}$"
    " (negativo = update ainda ajuda; dispersão = risco)",
    fontsize=10, y=1.02
)

gaps = sorted(df_b["staleness_gap"].unique())

# — Painel esq: dispersão (desvio padrão) do bias de loss por gap e função —
ax = axes[0]
for fn_name, label in fn_labels.items():
    grp = df_b[df_b["penalty_fn"] == fn_name]
    std_bias = grp.groupby("staleness_gap")["bias_loss"].std()
    ax.plot(gaps, std_bias[gaps], "o-", label=label,
            color=fn_colors[fn_name], markersize=5)

ax.set_xlabel(r"Gap de versão $\delta = t - \tau_k$")
ax.set_ylabel(r"Desvio padrão de $\Delta\mathcal{L}$ entre repetições")
ax.set_title("Dispersão (risco) do impacto vs Gap")
ax.legend(fontsize=8.5)

# — Painel dir: staleness_factor vs gap (curvas teóricas) —
ax2 = axes[1]
d = np.linspace(0, 20, 200)
ax2.plot(d, 1 / (1 + d),              label=fn_labels["hyperbolic"],
         color=fn_colors["hyperbolic"])
ax2.plot(d, np.exp(-0.5 * d),         label=fn_labels["exponential_05"],
         color=fn_colors["exponential_05"])
ax2.plot(d, np.exp(-0.1 * d),         label=fn_labels["exponential_01"],
         color=fn_colors["exponential_01"])
ax2.axhline(1.0, ls="--",             label=fn_labels["no_penalty"],
            color=fn_colors["no_penalty"])

ax2.set_xlabel(r"Gap de versão $\delta$")
ax2.set_ylabel(r"Fator de penalidade $f(\delta)$")
ax2.set_title("Funções de penalidade (teórico)")
ax2.legend(fontsize=9)

plt.tight_layout()
plt.savefig("fig2_staleness.pdf", bbox_inches="tight")
plt.savefig("fig2_staleness.png", bbox_inches="tight")
plt.close()
print("✓ fig2_staleness.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 3 — Ring Buffer: Preservação por tamanho de buffer × desconexão
# ════════════════════════════════════════════════════════════════════════════
df_c = pd.read_csv("exp_c_buffer.csv")
df_c["buffer_size"] = df_c["buffer_size"].apply(
    lambda v: v if v == "unbounded" else int(v)
)

fig, axes = plt.subplots(1, 2, figsize=(12, 4.5))
fig.suptitle(
    "Experimento C — Ring Buffer: Preservação de Updates sob Desconexões\n"
    r"(100 rounds por cenário; tamanhos de buffer simulados sob a mesma trajetória estocástica)",
    fontsize=10, y=1.02
)

rates = sorted(df_c["disconnect_rate"].unique())
rates_pct = [r * 100 for r in rates]
buffer_order = [0, 5, 20, "unbounded"]
buffer_labels = {0: "Sem buffer (B=0)", 5: "B=5 (AFL)", 20: "B=20", "unbounded": "Ilimitado"}

ax = axes[0]
for b in buffer_order:
    sub = df_c[df_c["buffer_size"] == b]
    pres_mean = sub.groupby("disconnect_rate")["preservation_ratio"].mean()
    pres_ci   = sub.groupby("disconnect_rate")["preservation_ratio"].apply(ci95)
    ax.plot(rates_pct, pres_mean[rates].values, "o-",
            color=BUFFER_COLORS[b], markersize=5, label=buffer_labels[b])
    ax.fill_between(rates_pct,
                    (pres_mean - pres_ci)[rates].values,
                    (pres_mean + pres_ci)[rates].values,
                    alpha=0.15, color=BUFFER_COLORS[b])

ax.set_xlabel("Taxa de desconexão (%)")
ax.set_ylabel("Preservation ratio")
ax.set_title("Preservação vs desconexão, por tamanho de buffer")
ax.legend(fontsize=8)
ax.set_ylim(-0.05, 1.1)

# — Painel dir: composição sent/flushed/dropped para B=5 (AFL) —
ax2 = axes[1]
df_c5 = df_c[df_c["buffer_size"] == 5]
agg_c = df_c5.groupby("disconnect_rate")[
    ["sent_directly", "flushed_from_buffer", "dropped_overflow"]
].mean()

width = 5
bottom_f = agg_c["sent_directly"].values
bottom_d = bottom_f + agg_c["flushed_from_buffer"].values

ax2.bar(rates_pct, agg_c["sent_directly"],      width=width,
        color=PALETTE["async"],  label="Enviados diretamente", alpha=0.85)
ax2.bar(rates_pct, agg_c["flushed_from_buffer"], width=width,
        bottom=bottom_f, color=PALETTE["converge"], label="Recuperados (flush)", alpha=0.85)
ax2.bar(rates_pct, agg_c["dropped_overflow"],    width=width,
        bottom=bottom_d, color=PALETTE["sync"],    label="Descartados (overflow)", alpha=0.85)

ax2.set_xlabel("Taxa de desconexão (%)")
ax2.set_ylabel("Updates (média por cenário)")
ax2.set_title("Composição dos updates — B=5 (AFL)")
ax2.legend(fontsize=9)

plt.tight_layout()
plt.savefig("fig3_buffer.pdf", bbox_inches="tight")
plt.savefig("fig3_buffer.png", bbox_inches="tight")
plt.close()
print("✓ fig3_buffer.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 4 — Convergência real: acurácia/loss ao longo das rodadas (MNIST)
# ════════════════════════════════════════════════════════════════════════════
df_d = pd.read_csv("exp_d_convergence.csv")

fig, axes = plt.subplots(1, 2, figsize=(12, 4.5))
fig.suptitle(
    "Experimento D — Convergência do AFL Incremental sobre MNIST non-IID\n"
    r"(MLP 784→32→10, FedAvg incremental, 10 repetições)",
    fontsize=11, y=1.02
)

idx = sorted(df_d["round"].unique())
mean_acc = df_d.groupby("round")["accuracy"].mean()
ci_acc   = df_d.groupby("round")["accuracy"].apply(ci95)

ax = axes[0]
ax.plot(idx, mean_acc[idx].values, color=PALETTE["converge"], label="Acurácia média (teste)")
ax.fill_between(idx,
                (mean_acc - ci_acc)[idx].values,
                (mean_acc + ci_acc)[idx].values,
                alpha=0.2, color=PALETTE["converge"], label="IC 95%")

ax.axhline(0.5, color="gray", ls=":", lw=1.2, label=r"Limiar 50% acc.")
conv_pt = next((i for i in idx if mean_acc[i] >= 0.5), None)
if conv_pt:
    ax.axvline(conv_pt, color=PALETTE["sync"], ls="--", lw=1.2,
               label=f"acc≥50% ≈ rodada {conv_pt}")

ax.set_xlabel("Rodada FedAvg")
ax.set_ylabel("Acurácia (held-out)")
ax.set_title("Acurácia de validação por rodada")
ax.legend(fontsize=9)

ax2 = axes[1]
mean_loss = df_d.groupby("round")["loss"].mean()
ci_loss   = df_d.groupby("round")["loss"].apply(ci95)

ax2.plot(idx, mean_loss[idx].values, color=PALETTE["buffer"], label="Loss médio (teste)")
ax2.fill_between(idx,
                 (mean_loss - ci_loss)[idx].values,
                 (mean_loss + ci_loss)[idx].values,
                 alpha=0.2, color=PALETTE["buffer"])

ax2.set_xlabel("Rodada FedAvg")
ax2.set_ylabel("Cross-entropy loss (held-out)")
ax2.set_title("Loss de validação por rodada")
ax2.legend(fontsize=9)

plt.tight_layout()
plt.savefig("fig4_convergence.pdf", bbox_inches="tight")
plt.savefig("fig4_convergence.png", bbox_inches="tight")
plt.close()
print("✓ fig4_convergence.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 6 — Comparação empírica com SSP (Exp. F) e FedAsync (Exp. G)
# ════════════════════════════════════════════════════════════════════════════
df_f = pd.read_csv("exp_f_ssp_throughput.csv")
df_g = pd.read_csv("exp_g_fedasync.csv")

fig, axes = plt.subplots(1, 2, figsize=(12, 4.5))
fig.suptitle(
    "Experimento F/G — Comparação Empírica com SSP e FedAsync\n"
    "(mesmo cenário de stragglers do Exp. A; mesma partição non-IID do Exp. D)",
    fontsize=10, y=1.02
)

ax = axes[0]
bounds = sorted(df_f["ssp_bound"].unique())
ssp_means = [df_f[df_f.ssp_bound == b]["ssp_updates_per_s"].mean() for b in bounds]
sync_mean = df_f["sync_updates_per_s"].drop_duplicates().mean()
async_mean = df_f["async_updates_per_s"].drop_duplicates().mean()

ax.plot(bounds, ssp_means, "o-", color="#D97706", markersize=6,
        label="Barreira de staleness (insp. SSP)")
ax.axhline(sync_mean, color=PALETTE["sync"], ls="--", label=f"Sync ({sync_mean:.1f})")
ax.axhline(async_mean, color=PALETTE["async"], ls="--", label=f"AFL irrestrito ({async_mean:.1f})")
for b, v in zip(bounds, ssp_means):
    ax.text(b, v + 3, f"{v:.1f}", ha="center", fontsize=8)
ax.set_xlabel("Bound de staleness $s$ (rodadas)")
ax.set_ylabel("Updates / segundo")
ax.set_title("(a) Throughput vs bound de staleness — Exp. F")
ax.legend(fontsize=8)

ax2 = axes[1]
idx_g = sorted(df_g["round"].unique())
alpha0_colors = {0.1: "#059669", 0.5: PALETTE["hyperbolic"], 0.9: "#D97706"}

afl_grp = df_g[df_g.method == "afl"]
mean_acc_afl = afl_grp.groupby("round")["accuracy"].mean()
ci_acc_afl = afl_grp.groupby("round")["accuracy"].apply(ci95)
ax2.plot(idx_g, mean_acc_afl[idx_g].values, color=PALETTE["async"], label="AFL (peso por $n_k$)")
ax2.fill_between(idx_g,
                 (mean_acc_afl - ci_acc_afl)[idx_g].values,
                 (mean_acc_afl + ci_acc_afl)[idx_g].values,
                 alpha=0.15, color=PALETTE["async"])

for a0 in [0.1, 0.5, 0.9]:
    grp = df_g[(df_g.method == "fedasync") & (df_g.alpha0 == a0)]
    mean_acc_g = grp.groupby("round")["accuracy"].mean()
    ci_acc_g = grp.groupby("round")["accuracy"].apply(ci95)
    ax2.plot(idx_g, mean_acc_g[idx_g].values, color=alpha0_colors[a0],
              label=fr"FedAsync ($\alpha_0={a0}$)")
    ax2.fill_between(idx_g,
                     (mean_acc_g - ci_acc_g)[idx_g].values,
                     (mean_acc_g + ci_acc_g)[idx_g].values,
                     alpha=0.12, color=alpha0_colors[a0])
ax2.set_xlabel("Rodada FedAvg")
ax2.set_ylabel("Acurácia (held-out)")
ax2.set_title("(b) Regra de mistura: AFL vs FedAsync (sweep de $\\alpha_0$) — Exp. G")
ax2.legend(fontsize=7.5)

plt.tight_layout()
plt.savefig("fig6_baselines.pdf", bbox_inches="tight")
plt.savefig("fig6_baselines.png", bbox_inches="tight")
plt.close()
print("✓ fig6_baselines.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 7 — Experimento H: Resiliência sob injeção de falhas
# ════════════════════════════════════════════════════════════════════════════
df_h1 = pd.read_csv("exp_h1_data_loss.csv")
df_h2 = pd.read_csv("exp_h2_recovery_time.csv")
df_h3 = pd.read_csv("exp_h3_model_loss.csv")

fig, axes = plt.subplots(1, 3, figsize=(16, 4.5))
fig.suptitle(
    "Experimento R — Resiliência sob Injeção de Falhas\n"
    "(crash do EdgeNode e do Aggregator, antes/depois das correções; distribuição de tempo de recuperação)",
    fontsize=10, y=1.03
)

ax = axes[0]
loss_by_mech = df_h1.groupby("mechanism")["entries_lost"].sum()
written_by_mech = df_h1.groupby("mechanism")["entries_written"].sum()
mechs = ["sem_heir", "com_heir"]
mech_labels = ["Sem herdeiro\n(design original)", "Com herdeiro\n(AFL.BufferKeeper)"]
loss_pct = [100 * loss_by_mech[m] / written_by_mech[m] for m in mechs]
colors_h = [PALETTE["sync"], PALETTE["converge"]]

bars = ax.bar(mech_labels, loss_pct, color=colors_h, alpha=0.85)
for bar, val, m in zip(bars, loss_pct, mechs):
    ax.text(bar.get_x() + bar.get_width()/2, val + 2, f"{val:.0f}%\n({loss_by_mech[m]}/{written_by_mech[m]})",
            ha="center", va="bottom", fontsize=9, fontweight="bold")
ax.set_ylabel("Gradientes perdidos (%)")
ax.set_ylim(0, 110)
ax.set_title(f"(a) Perda de gradientes\nao crash do EdgeNode ({df_h1.trial.nunique()} crashes/mecanismo)", fontsize=9.5)

ax2 = axes[1]
loss_by_mech3 = df_h3.groupby("mechanism")["rounds_lost"].sum()
trained_by_mech3 = df_h3.groupby("mechanism")["rounds_trained"].sum()
mechs3 = ["sem_keeper", "com_keeper"]
mech_labels3 = ["Sem ModelKeeper\n(design original)", "Com ModelKeeper\n(corrigido)"]
loss_pct3 = [100 * loss_by_mech3[m] / trained_by_mech3[m] for m in mechs3]

bars3 = ax2.bar(mech_labels3, loss_pct3, color=colors_h, alpha=0.85)
for bar, val, m in zip(bars3, loss_pct3, mechs3):
    ax2.text(bar.get_x() + bar.get_width()/2, val + 2, f"{val:.0f}%\n({loss_by_mech3[m]}/{trained_by_mech3[m]})",
             ha="center", va="bottom", fontsize=9, fontweight="bold")
ax2.set_ylabel("Rodadas de treino perdidas (%)")
ax2.set_ylim(0, 110)
ax2.set_title(f"(b) Perda do MODELO GLOBAL\nao crash do Aggregator ({df_h3.trial.nunique()} crashes/mecanismo)", fontsize=9.5)

ax3 = axes[2]
targets = ["aggregator", "edge_node"]
target_labels = ["Aggregator", "EdgeNode\n(supervisionado)"]
data_to_plot = [df_h2[df_h2.target == t]["recovery_ms"].values for t in targets]
bp = ax3.boxplot(data_to_plot, tick_labels=target_labels, patch_artist=True, widths=0.5)
for patch, color in zip(bp["boxes"], [PALETTE["async"], PALETTE["hyperbolic"]]):
    patch.set_facecolor(color)
    patch.set_alpha(0.5)
for t, d in zip(targets, data_to_plot):
    ax3.scatter([targets.index(t) + 1] * len(d), d, alpha=0.5, s=15, color="black", zorder=5)
ax3.set_ylabel("Tempo de recuperação (ms)")
ax3.set_title(f"(c) Distribuição do tempo\nde recuperação ({df_h2.trial.nunique()} crashes/alvo)", fontsize=9.5)

plt.tight_layout()
plt.savefig("fig7_resilience.pdf", bbox_inches="tight")
plt.savefig("fig7_resilience.png", bbox_inches="tight")
plt.close()
print("✓ fig7_resilience.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 8 — Experimento R4 (falha concorrente) e R5 (crash do dono sob posse invertida)
# ════════════════════════════════════════════════════════════════════════════
df_r4_fig = pd.read_csv("exp_r4_concurrent_crash.csv")
df_r5_fig = pd.read_csv("exp_r5_heir_crash.csv")

fig, (ax_r4, ax_r5) = plt.subplots(1, 2, figsize=(11, 4.5))
fig.suptitle(
    "Experimento R4/R5 — Falha Concorrente e Crash do Dono sob Posse Invertida\n"
    "(EdgeNode e Aggregator crashando juntos; BufferKeeper/ModelKeeper mortos, não os workers)",
    fontsize=10, y=1.03
)

buf_lost_pct = 100 * df_r4_fig["buffer_entries_lost"].sum() / df_r4_fig["buffer_entries_written"].sum()
mdl_lost_pct = 100 * df_r4_fig["rounds_lost"].sum() / df_r4_fig["training_rounds"].sum()
bars_r4 = ax_r4.bar(
    ["Buffer\n(EdgeNode)", "Modelo\n(Aggregator)"], [buf_lost_pct, mdl_lost_pct],
    color=[PALETTE["converge"], PALETTE["converge"]], alpha=0.85
)
for bar, val in zip(bars_r4, [buf_lost_pct, mdl_lost_pct]):
    ax_r4.text(bar.get_x() + bar.get_width() / 2, val + 2, f"{val:.0f}%",
               ha="center", va="bottom", fontsize=9, fontweight="bold")
ax_r4.set_ylabel("Perdido sob falha concorrente (%)")
ax_r4.set_ylim(0, 110)
ax_r4.set_title(f"(a) R4 — EdgeNode + Aggregator\ncrasham juntos ({df_r4_fig.trial.nunique()} trials)", fontsize=9.5)

r5_buffer = df_r5_fig[df_r5_fig.scenario == "buffer_dono_morto"]
r5_modelo = df_r5_fig[df_r5_fig.scenario == "modelo_dono_morto"]
pct_buffer = 100 * r5_buffer["entries_lost"].sum() / r5_buffer["entries_written"].sum()
pct_modelo = 100 * r5_modelo["entries_lost"].sum() / r5_modelo["entries_written"].sum()
bars_r5 = ax_r5.bar(
    ["Buffer\n(BufferKeeper morto)", "Modelo\n(ModelKeeper morto)"], [pct_buffer, pct_modelo],
    color=[PALETTE["sync"], PALETTE["converge"]], alpha=0.85
)
for bar, val in zip(bars_r5, [pct_buffer, pct_modelo]):
    ax_r5.text(bar.get_x() + bar.get_width() / 2, val + 2, f"{val:.0f}%",
               ha="center", va="bottom", fontsize=9, fontweight="bold")
ax_r5.set_ylabel("Perdido sob crash do dono (%)")
ax_r5.set_ylim(0, 110)
ax_r5.set_title(f"(b) R5 — Crash do dono, posse\ninvertida ({r5_buffer.trial.nunique()} trials/cenário)", fontsize=9.5)

plt.tight_layout()
plt.savefig("fig8_r4_r5.pdf", bbox_inches="tight")
plt.savefig("fig8_r4_r5.png", bbox_inches="tight")
plt.close()
print("✓ fig8_r4_r5.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 9 — Validação em rede real: simulado (Exp. A) vs distribuído de fato
# ════════════════════════════════════════════════════════════════════════════
df_ad_fig = pd.read_csv("../distributed_bench/results/exp_a_distributed.csv")

fig, (ax_ups, ax_speedup) = plt.subplots(1, 2, figsize=(11, 4.5))
fig.suptitle(
    "Validação em Rede Real — Simulado (single-VM) vs Distribuído de Fato (Docker, TCP real)\n"
    "(mesmo cenário de stragglers do Experimento A: K=5, latências [10,10,20,50,500] ms)",
    fontsize=10, y=1.03
)

labels = ["Async", "Sync"]
sim_vals = [agg["async_updates_per_s"].mean(), agg["sync_updates_per_s"].mean()]
sim_ci = [ci95(agg["async_updates_per_s"]), ci95(agg["sync_updates_per_s"])]
real_vals = [df_ad_fig["async_updates_per_s"].mean(), df_ad_fig["sync_updates_per_s"].mean()]
real_ci = [ci95(df_ad_fig["async_updates_per_s"]), ci95(df_ad_fig["sync_updates_per_s"])]

x = np.arange(len(labels))
width = 0.35
ax_ups.bar(x - width/2, sim_vals, width, yerr=sim_ci, capsize=4, label="Simulado (Exp. A)", color=PALETTE["async"], alpha=0.85)
ax_ups.bar(x + width/2, real_vals, width, yerr=real_ci, capsize=4, label="Real (Docker/TCP)", color=PALETTE["converge"], alpha=0.85)
ax_ups.set_xticks(x)
ax_ups.set_xticklabels(labels)
ax_ups.set_ylabel("Updates / segundo")
ax_ux_title = f"(a) Throughput — {df_ad_fig.shape[0]} repetições reais"
ax_ups.set_title(ax_ux_title, fontsize=9.5)
ax_ups.legend(fontsize=8)

sim_speedup = agg["speedup"].mean()
sim_speedup_ci = ci95(agg["speedup"])
real_speedup = df_ad_fig["speedup"].mean()
real_speedup_ci = ci95(df_ad_fig["speedup"])
bars_sp = ax_speedup.bar(
    ["Simulado\n(Exp. A)", "Real\n(Docker/TCP)"], [sim_speedup, real_speedup],
    yerr=[sim_speedup_ci, real_speedup_ci], capsize=5,
    color=[PALETTE["async"], PALETTE["converge"]], alpha=0.85
)
for bar, val in zip(bars_sp, [sim_speedup, real_speedup]):
    ax_speedup.text(bar.get_x() + bar.get_width()/2, val + 0.5, f"{val:.1f}×",
                     ha="center", va="bottom", fontsize=9, fontweight="bold")
ax_speedup.set_ylabel("Speedup (Async / Sync)")
ax_speedup.set_title("(b) Speedup — mesma ordem de grandeza", fontsize=9.5)

plt.tight_layout()
plt.savefig("fig9_distributed_validation.pdf", bbox_inches="tight")
plt.savefig("fig9_distributed_validation.png", bbox_inches="tight")
plt.close()
print("✓ fig9_distributed_validation.pdf")

# ════════════════════════════════════════════════════════════════════════════
# FIGURA 5 — Painel resumo (4-em-1) para submissão
# ════════════════════════════════════════════════════════════════════════════
fig = plt.figure(figsize=(14, 9))
gs  = gridspec.GridSpec(2, 2, hspace=0.45, wspace=0.35)

ax_a = fig.add_subplot(gs[0, 0])
agg2 = df_a.drop_duplicates("repetition")
labels = ["AFL\nAssíncrono", "FedAvg\nSíncrono"]
means  = [agg2["async_updates_per_s"].mean(), agg2["sync_updates_per_s"].mean()]
cis    = [ci95(agg2["async_updates_per_s"]),   ci95(agg2["sync_updates_per_s"])]
colors = [PALETTE["async"], PALETTE["sync"]]

bars = ax_a.bar(labels, means, color=colors, alpha=0.85, width=0.5, yerr=cis,
                capsize=5, error_kw={"linewidth": 1.5})
ax_a.set_ylabel("Updates / segundo")
ax_a.set_title(f"(a) Throughput médio\nSpeedup: {agg2['speedup'].mean():.1f}×", fontsize=10)
for bar, val in zip(bars, means):
    ax_a.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 2,
              f"{val:.1f}", ha="center", va="bottom", fontsize=9, fontweight="bold")

ax_b = fig.add_subplot(gs[0, 1])
for fn_name, label in fn_labels.items():
    grp = df_b[df_b["penalty_fn"] == fn_name]
    std_bias = grp.groupby("staleness_gap")["bias_loss"].std()
    ax_b.plot(gaps, std_bias[gaps], "o-", label=label,
              color=fn_colors[fn_name], markersize=4)
ax_b.set_xlabel(r"Gap de versão $\delta$", fontsize=9)
ax_b.set_ylabel(r"Desvio padrão de $\Delta\mathcal{L}$", fontsize=9)
ax_b.set_title("(b) Risco de staleness por penalidade", fontsize=10)
ax_b.legend(fontsize=7.5)

ax_c = fig.add_subplot(gs[1, 0])
for b in buffer_order:
    sub = df_c[df_c["buffer_size"] == b]
    pres_mean_b = sub.groupby("disconnect_rate")["preservation_ratio"].mean()
    ax_c.plot(rates_pct, pres_mean_b[rates].values, "o-",
              color=BUFFER_COLORS[b], markersize=4, label=buffer_labels[b])
ax_c.set_xlabel("Taxa de desconexão (%)", fontsize=9)
ax_c.set_ylabel("Preservation ratio", fontsize=9)
ax_c.set_title("(c) Ring buffer por tamanho", fontsize=10)
ax_c.legend(fontsize=7)
ax_c.set_ylim(-0.05, 1.1)

ax_d = fig.add_subplot(gs[1, 1])
ax_d.plot(idx, mean_acc[idx].values, color=PALETTE["converge"])
ax_d.fill_between(idx,
                  (mean_acc - ci_acc)[idx].values,
                  (mean_acc + ci_acc)[idx].values,
                  alpha=0.2, color=PALETTE["converge"])
ax_d.axhline(0.5, color="gray", ls=":", lw=1)
if conv_pt:
    ax_d.axvline(conv_pt, color=PALETTE["sync"], ls="--", lw=1.2)
    ax_d.text(conv_pt + 2, mean_acc.min() + 0.05,
              f"≈{conv_pt} rodadas", fontsize=8, color=PALETTE["sync"])
ax_d.set_xlabel("Rodada FedAvg", fontsize=9)
ax_d.set_ylabel("Acurácia (held-out)", fontsize=9)
ax_d.set_title("(d) Convergência real (MNIST, IC 95%)", fontsize=10)

fig.suptitle(
    "Aprendizado Federado Assíncrono em Edge Computing — Resultados Experimentais",
    fontsize=13, fontweight="bold", y=1.01
)

plt.savefig("fig5_summary_panel.pdf", bbox_inches="tight")
plt.savefig("fig5_summary_panel.png", bbox_inches="tight")
plt.close()
print("✓ fig5_summary_panel.pdf")

# ════════════════════════════════════════════════════════════════════════════
# Tabela de Testes Estatísticos
# ════════════════════════════════════════════════════════════════════════════
print("\n" + "═" * 60)
print("TESTES ESTATÍSTICOS")
print("═" * 60)

# H1: Throughput Async vs Sync
agg3 = df_a.drop_duplicates("repetition")
t, p = stats.ttest_rel(agg["async_updates_per_s"], agg["sync_updates_per_s"])
sig = "***" if p < 0.001 else "**" if p < 0.01 else "*" if p < 0.05 else "ns"
d = cohens_d(agg["async_updates_per_s"], agg["sync_updates_per_s"])
# t/p/d são reatribuídos como variáveis de loop mais abaixo no script (ex.:
# "for t, label in ..." no bloco do Exp. H2) — aliases dedicados para a
# seção de macros no fim do arquivo, que roda depois de todos esses loops.
t_expA, p_expA, d_expA = t, p, d
print(f"\nH1 — Async vs Sync throughput (teste t pareado):")
print(f"  t({len(agg3)-1}) = {t:.3f}  |  p = {p:.2e}  |  d = {d:.2f}  |  {sig}")
print(f"  Async médio: {agg3['async_updates_per_s'].mean():.1f} upd/s")
print(f"  Sync  médio: {agg3['sync_updates_per_s'].mean():.1f} upd/s")
print(f"  Speedup:     {agg3['speedup'].mean():.2f}× ± {ci95(agg3['speedup']):.2f}")

# H2: Preservation ratio — tendência com taxa de desconexão, por tamanho de buffer
from scipy.stats import pearsonr
print(f"\nH2 — Ring buffer preservation vs disconnect rate (Pearson r), por tamanho de buffer:")
h2_pvals = {}  # buffer_size -> p (só os tamanhos finitos entram na família de correção)
for b in buffer_order:
    sub = df_c[df_c["buffer_size"] == b]
    r, p_corr = pearsonr(sub["disconnect_rate"], sub["preservation_ratio"])
    sig_c = "***" if p_corr < 0.001 else "**" if p_corr < 0.01 else "*" if p_corr < 0.05 else "ns"
    print(f"  {buffer_labels[b]:<16}: r = {r:.3f}  |  p = {p_corr:.2e}  |  {sig_c}")
    if b != "unbounded":
        h2_pvals[b] = p_corr

# H3: bias real de staleness — ANOVA sobre bias_loss (gap=10) + variância como
# métrica complementar (ver discussão: penalidade reduz principalmente a
# DISPERSÃO/risco do impacto, não necessariamente a média — pois updates
# atrasados reais, vindos de treino genuíno, não são "venenosos" por
# definição, ao contrário do poison update sintético da versão anterior).
gap10 = df_b[df_b["staleness_gap"] == 10]
groups_h3 = [g["bias_loss"].values for _, g in gap10.groupby("penalty_fn")]
f, p_anova = stats.f_oneway(*groups_h3)
print(f"\nH3 — ANOVA de bias de loss por função de penalidade (gap=10):")
print(f"  F = {f:.3f}  |  p = {p_anova:.4f}  |  {'***' if p_anova < 0.001 else '**' if p_anova < 0.01 else '*' if p_anova < 0.05 else 'ns'}")
for fn_name, grp in gap10.groupby("penalty_fn"):
    print(f"  {fn_name:<20}: Δloss médio = {grp['bias_loss'].mean():+.5f} ± {ci95(grp['bias_loss']):.5f}"
          f"  |  std = {grp['bias_loss'].std():.5f}")

no_pen_std = df_b[df_b.penalty_fn == "no_penalty"].groupby("staleness_gap")["bias_loss"].std()
hyp_std    = df_b[df_b.penalty_fn == "hyperbolic"].groupby("staleness_gap")["bias_loss"].std()
reduction  = 1 - (hyp_std[20] / no_pen_std[20])
print(f"\n  Redução de dispersão (std) em δ=20, hiperbólica vs sem penalidade: {reduction*100:.1f}%")

# Exp. E — overhead de memória real
df_e = pd.read_csv("exp_e_memory.csv")
print(f"\nExp. E — Overhead de memória do ring buffer (medido, não especulado):")
for _, row in df_e.iterrows():
    print(f"  {row['weight_kind']:<16}: {row['bytes_per_entry']:.0f} bytes/entrada × "
          f"{row['buffer_capacity']:.0f} slots = {row['buffer_total_kb']:.2f} KB")

# Exp. F — AFL vs SSP sob stragglers
print(f"\nExp. F — Throughput AFL vs SSP (mesmo cenário de stragglers do Exp. A):")
print(f"  Sync            : {df_f['sync_updates_per_s'].drop_duplicates().mean():.1f} upd/s")
for bound in sorted(df_f["ssp_bound"].unique()):
    v = df_f[df_f.ssp_bound == bound]["ssp_updates_per_s"].mean()
    print(f"  SSP (bound={bound})   : {v:.1f} upd/s")
print(f"  AFL (irrestrito): {df_f['async_updates_per_s'].drop_duplicates().mean():.1f} upd/s")

# Exp. G — AFL vs FedAsync, regra de mistura (pareado por init + ordem de nós)
final_g = df_g[df_g["round"] == df_g["round"].max()]
afl_acc = final_g[final_g.method == "afl"].sort_values("repetition")["accuracy"].values
print(f"\nExp. G — Regra de mistura AFL vs FedAsync (rodada {df_g['round'].max()}, pareado, teste t):")
print(f"  AFL              : acurácia média = {afl_acc.mean():.3f} ± {ci95(pd.Series(afl_acc)):.3f}")
h5_pvals = {}  # alpha0 -> p
for a0 in sorted(df_g[df_g.method == "fedasync"]["alpha0"].unique()):
    fa_acc = final_g[(final_g.method == "fedasync") & (final_g.alpha0 == a0)].sort_values("repetition")["accuracy"].values
    t_g, p_g = stats.ttest_rel(fa_acc, afl_acc)
    sig = "***" if p_g < 0.001 else "**" if p_g < 0.01 else "*" if p_g < 0.05 else "ns"
    print(f"  FedAsync (α₀={a0}): acurácia média = {fa_acc.mean():.3f} ± {ci95(pd.Series(fa_acc)):.3f}"
          f"  |  t = {t_g:.3f}  |  p = {p_g:.2e}  |  {sig}")
    h5_pvals[a0] = p_g
print(f"  α₀=0,1 e 0,5 superam o AFL significativamente; α₀=0,9 empata com o AFL (alta variância)")

# ── Correção de Holm-Bonferroni sobre a família de 8 testes de hipótese
# correlacionados deste estudo (H1; H2 para B=5,20,0; H3; H5 para
# α₀=0,1,0,5,0,9) — reportar p bruto isoladamente, sem correção para
# comparações múltiplas, infla a taxa de falso-positivo da família como um
# todo mesmo que cada teste individual seja válido.
def holm_bonferroni(pvals):
    n = len(pvals)
    order = sorted(range(n), key=lambda i: pvals[i])
    adjusted = [None] * n
    running_max = 0.0
    for rank, idx in enumerate(order):
        adj = min(pvals[idx] * (n - rank), 1.0)
        running_max = max(running_max, adj)
        adjusted[idx] = running_max
    return adjusted

BUFFER_TAG = {5: "BFive", 20: "BTwenty", 0: "BZero"}
ALPHA_TAG = {0.1: "AlphaOne", 0.5: "AlphaFive", 0.9: "AlphaNine"}
holm_tags = ["H1"] + [f"H2{BUFFER_TAG[b]}" for b in h2_pvals] + ["H3"] + \
    [f"H5{ALPHA_TAG[a]}" for a in h5_pvals]
holm_labels = (
    ["H1"] + [f"H2 (B={b})" for b in h2_pvals] + ["H3"] + [f"H5 (α0={a})" for a in h5_pvals]
)
holm_family_pvals = [p_expA] + list(h2_pvals.values()) + [p_anova] + list(h5_pvals.values())
holm_adjusted = holm_bonferroni(holm_family_pvals)
holm_by_tag = dict(zip(holm_tags, holm_adjusted))

print(f"\nCorreção de Holm-Bonferroni sobre a família de {len(holm_family_pvals)} testes "
      f"(H1, H2×3, H3, H5×3):")
for label, p_raw, p_adj in zip(holm_labels, holm_family_pvals, holm_adjusted):
    print(f"  {label:<14}: p_bruto = {p_raw:.2e}  |  p_ajustado = {p_adj:.2e}")

# Exp. H — Resiliência sob injeção de falhas
print(f"\nExp. H1 — Perda de gradientes ao crash do EdgeNode ({df_h1.trial.nunique()} crashes/mecanismo):")
for m, label in [("sem_heir", "Sem herdeiro (original)"), ("com_heir", "Com herdeiro (corrigido)")]:
    lost = df_h1[df_h1.mechanism == m]["entries_lost"].sum()
    written = df_h1[df_h1.mechanism == m]["entries_written"].sum()
    print(f"  {label:<28}: {lost}/{written} gradientes perdidos ({100*lost/written:.0f}%)")

print(f"\nExp. H2 — Tempo de recuperação sob crash ({df_h2.trial.nunique()} crashes/alvo):")
for t, label in [("aggregator", "Aggregator"), ("edge_node", "EdgeNode (supervisionado)")]:
    d = df_h2[df_h2.target == t]["recovery_ms"]
    print(f"  {label:<26}: média={d.mean():.3f}ms | p50={d.median():.3f}ms | "
          f"p95={d.quantile(0.95):.3f}ms | max={d.max():.3f}ms")

print(f"\nExp. H3 — Perda do MODELO GLOBAL ao crash do Aggregator ({df_h3.trial.nunique()} crashes/mecanismo):")
for m, label in [("sem_keeper", "Sem ModelKeeper (original)"), ("com_keeper", "Com ModelKeeper (corrigido)")]:
    lost = df_h3[df_h3.mechanism == m]["rounds_lost"].sum()
    trained = df_h3[df_h3.mechanism == m]["rounds_trained"].sum()
    print(f"  {label:<30}: {lost}/{trained} rodadas de treino perdidas ({100*lost/trained:.0f}%)")

# ════════════════════════════════════════════════════════════════════════════
# Macros LaTeX — fonte única de verdade para os números citados em main.tex
#
# Antes desta seção, cada estatística citada no artigo (Abstract, Resultados,
# Discussão, Conclusão) era texto literal digitado à mão em cada lugar — a
# causa mecânica de pelo menos 5 divergências encontradas em rodadas de
# revisão adversarial anteriores (ex.: t=770,5 na Conclusão vs t=341,9 nos
# Resultados, mesmo dado). Esta seção reaproveita as variáveis já calculadas
# acima (sem recalcular nada) e emite um `\newcommand` por estatística em
# artigo/stats_macros.tex, que main.tex consome via `\input`. Uma estatística
# citada em 3 lugares agora tem uma única fonte — se o número mudar numa
# reexecução, muda em todo lugar automaticamente.
# ════════════════════════════════════════════════════════════════════════════

def texnum(x, decimals=1):
    """Formata um número com vírgula decimal (convenção pt-BR do artigo)."""
    s = f"{x:.{decimals}f}"
    if "." in s:
        sign = "-" if s.startswith("-") else ""
        intpart, frac = s.lstrip("-").split(".")
        return f"{sign}{intpart}{{,}}{frac}"
    return s

def p_bound_tex(p):
    """Maior N inteiro tal que p < 10^-N seja uma afirmação verdadeira —
    mesma convenção de bound conservador já usada no texto do artigo."""
    if p <= 0:
        return "10^{-300}"
    n = math.floor(-math.log10(p))
    return f"10^{{-{n}}}"

def p_value_tex(p):
    """Valor para depois de '$p <$' (bound conservador, se significativo)
    ou de '$p =$' (valor literal, se não) — replica a convenção já usada
    manualmente no texto do artigo. p_bound_tex sozinho degenera para
    resultados não-significativos (ex.: p=0,36 -> '10^{-0}', sem sentido)."""
    if p < 0.05:
        return p_bound_tex(p)
    return texnum(p, 2)

def sig_threshold_tex(p):
    """Menor limiar-padrão (0,05/0,01/0,001/0,0001) que p ainda satisfaz —
    para reportar 'p<0,0001' em vez do valor exato, como já era feito à mão."""
    for edge, label in [(0.0001, "0{,}0001"), (0.001, "0{,}001"),
                         (0.01, "0{,}01"), (0.05, "0{,}05")]:
        if p < edge:
            return label
    return f"{texnum(p, 4)}"

macros = {}

# Nomes de comando LaTeX NÃO podem conter dígitos (\newcommand com dígito no
# nome causa "Missing \begin{document}" ou erros em cascata) — todo sufixo
# numérico de macro usa palavra, nunca o algarismo.
NUMWORD = {0: "Zero", 1: "One", 2: "Two", 5: "Five", 9: "Nine",
           10: "Ten", 20: "Twenty", 50: "Fifty"}

# Exp. A — Throughput Async vs Sync
macros["statExpASpeedup"] = texnum(agg["speedup"].mean(), 2) + r"\times"
macros["statExpATStat"] = texnum(t_expA, 1)
macros["statExpAPValue"] = p_bound_tex(p_expA)
macros["statExpACohenD"] = texnum(d_expA, 1)
macros["statExpAAsyncUps"] = texnum(agg["async_updates_per_s"].mean(), 1)
macros["statExpASyncUps"] = texnum(agg["sync_updates_per_s"].mean(), 1)

# Correção de Holm-Bonferroni (família de 8 testes: H1, H2×3, H3, H5×3) —
# ver bloco de cálculo acima (holm_by_tag). Reporta o p ajustado ao lado do
# bruto para toda a família.
macros["statHolmFamilySize"] = str(len(holm_family_pvals))
macros["statHolmPValueHOne"] = p_value_tex(holm_by_tag["H1"])
macros["statHolmPValueHTwoBFive"] = p_value_tex(holm_by_tag["H2BFive"])
macros["statHolmPValueHTwoBTwenty"] = p_value_tex(holm_by_tag["H2BTwenty"])
macros["statHolmPValueHTwoBZero"] = p_value_tex(holm_by_tag["H2BZero"])
macros["statHolmPValueHThree"] = p_value_tex(holm_by_tag["H3"])
macros["statHolmPValueHFiveAlphaOne"] = p_value_tex(holm_by_tag["H5AlphaOne"])
macros["statHolmPValueHFiveAlphaFive"] = p_value_tex(holm_by_tag["H5AlphaFive"])
macros["statHolmPValueHFiveAlphaNine"] = p_value_tex(holm_by_tag["H5AlphaNine"])

# Exp. B — Staleness: reduções de dispersão por função/gap + ANOVA (gap=10)
exp05_std = df_b[df_b.penalty_fn == "exponential_05"].groupby("staleness_gap")["bias_loss"].std()
hyp_reduction_10 = 1 - (hyp_std[10] / no_pen_std[10])
exp05_reduction_10 = 1 - (exp05_std[10] / no_pen_std[10])

macros["statExpBHypReductionGapTen"] = texnum(hyp_reduction_10 * 100, 1)
macros["statExpBHypReductionGapTwenty"] = texnum(reduction * 100, 1)
macros["statExpBExpFiveReductionGapTen"] = texnum(exp05_reduction_10 * 100, 1)
macros["statExpBAnovaF"] = texnum(f, 2)
macros["statExpBAnovaPBound"] = sig_threshold_tex(p_anova)

# Exp. C — Correlação preservação × taxa de desconexão, por tamanho de buffer
for b, tag in [(5, "BFive"), (20, "BTwenty"), (0, "BZero")]:
    sub = df_c[df_c["buffer_size"] == b]
    r_c, p_c = pearsonr(sub["disconnect_rate"], sub["preservation_ratio"])
    macros[f"statExpCCorr{tag}R"] = texnum(r_c, 2)
    macros[f"statExpCCorr{tag}PValue"] = p_bound_tex(p_c)

# Preservação a 50% de desconexão — B=5 (AFL) vs sem buffer vs B=20
for b, tag in [(5, "BFive"), (0, "BZero"), (20, "BTwenty")]:
    pres_50 = df_c[(df_c.buffer_size == b) & (df_c.disconnect_rate == 0.5)]["preservation_ratio"].mean()
    macros[f"statExpCPreservationFifty{tag}"] = texnum(pres_50 * 100, 1)

# Tabela completa de preservação (Tabela IV) — TODA célula vem de macro,
# não texto digitado à mão; foi exatamente a falta disso que causou uma
# divergência real entre esta tabela e o Abstract/Conclusão (a tabela
# ficou parada numa execução antiga enquanto Abstract/Conclusão já usavam
# a macro atualizada) — achado da 11ª rodada de revisão adversarial.
RATE_TAG = {0.0: "Zero", 0.1: "Ten", 0.3: "Thirty", 0.5: "Fifty", 0.7: "Seventy", 0.9: "Ninety"}
BUF_TABLE_TAG = {0: "BZero", 5: "BFive", 20: "BTwenty", "unbounded": "BUnbounded"}
for rate, rtag in RATE_TAG.items():
    for b, btag in BUF_TABLE_TAG.items():
        v = df_c[(df_c.buffer_size == b) & (df_c.disconnect_rate == rate)]["preservation_ratio"].mean()
        macros[f"statExpCTableRate{rtag}{btag}"] = texnum(v, 3)

# Exp. D — Convergência real
macros["statExpDFinalAcc"] = texnum(mean_acc[idx].iloc[-1] * 100, 1)
macros["statExpDFinalAccCI"] = texnum(ci_acc[idx].iloc[-1] * 100, 1)
macros["statExpDConvergeRound"] = str(conv_pt) if conv_pt else "?"

# Exp. F — AFL vs SSP (mesmo cenário de stragglers do Exp. A)
macros["statExpFSyncUps"] = texnum(df_f["sync_updates_per_s"].drop_duplicates().mean(), 1)
macros["statExpFAsyncUps"] = texnum(df_f["async_updates_per_s"].drop_duplicates().mean(), 1)
for bound in sorted(df_f["ssp_bound"].unique()):
    v = df_f[df_f.ssp_bound == bound]["ssp_updates_per_s"].mean()
    macros[f"statExpFSspUps{NUMWORD[bound]}"] = texnum(v, 1)

# Exp. G — AFL vs FedAsync (pareado, teste t) — ALPHA_TAG definido acima,
# junto da correção de Holm-Bonferroni.
macros["statExpGAflAcc"] = texnum(afl_acc.mean() * 100, 1)
macros["statExpGAflAccCI"] = texnum(ci95(pd.Series(afl_acc)) * 100, 1)
for a0 in sorted(df_g[df_g.method == "fedasync"]["alpha0"].unique()):
    fa_acc = final_g[(final_g.method == "fedasync") & (final_g.alpha0 == a0)].sort_values("repetition")["accuracy"].values
    t_g, p_g = stats.ttest_rel(fa_acc, afl_acc)
    tag = ALPHA_TAG[a0]
    macros[f"statExpGFedAsyncAcc{tag}"] = texnum(fa_acc.mean() * 100, 1)
    macros[f"statExpGFedAsyncAccCI{tag}"] = texnum(ci95(pd.Series(fa_acc)) * 100, 1)
    macros[f"statExpGFedAsyncTStat{tag}"] = texnum(t_g, 2)
    macros[f"statExpGFedAsyncPValue{tag}"] = p_value_tex(p_g)

# Exp. R-um/R-dois/R-três (CSVs exp_h1/h2/h3) — resiliência sob injeção de falhas
for m, tag in [("sem_heir", "SemHeir"), ("com_heir", "ComHeir")]:
    lost = df_h1[df_h1.mechanism == m]["entries_lost"].sum()
    written = df_h1[df_h1.mechanism == m]["entries_written"].sum()
    macros[f"statExpROne{tag}Lost"] = str(lost)
    macros[f"statExpROne{tag}Written"] = str(written)
    macros[f"statExpROne{tag}Pct"] = str(round(100 * lost / written))

for m, tag in [("sem_keeper", "SemKeeper"), ("com_keeper", "ComKeeper")]:
    lost = df_h3[df_h3.mechanism == m]["rounds_lost"].sum()
    trained = df_h3[df_h3.mechanism == m]["rounds_trained"].sum()
    macros[f"statExpRTwo{tag}Lost"] = str(lost)
    macros[f"statExpRTwo{tag}Trained"] = str(trained)
    macros[f"statExpRTwo{tag}Pct"] = str(round(100 * lost / trained))

for t_name, tag in [("aggregator", "Aggregator"), ("edge_node", "EdgeNode")]:
    dd = df_h2[df_h2.target == t_name]["recovery_ms"]
    macros[f"statExpRThree{tag}Median"] = texnum(dd.median(), 2)
    macros[f"statExpRThree{tag}Mean"] = texnum(dd.mean(), 2)

# Exp. R4 — falha concorrente (EdgeNode + Aggregator crasham juntos)
df_r4 = pd.read_csv("exp_r4_concurrent_crash.csv")
r4_buf_lost = df_r4["buffer_entries_lost"].sum()
r4_buf_written = df_r4["buffer_entries_written"].sum()
r4_rounds_lost = df_r4["rounds_lost"].sum()
r4_rounds_trained = df_r4["training_rounds"].sum()
macros["statExpRFourBufferLost"] = str(r4_buf_lost)
macros["statExpRFourBufferWritten"] = str(r4_buf_written)
macros["statExpRFourRoundsLost"] = str(r4_rounds_lost)
macros["statExpRFourRoundsTrained"] = str(r4_rounds_trained)
macros["statExpRFourTrials"] = str(len(df_r4))

# Exp. R5 — crash do dono sob posse invertida (BufferKeeper/ModelKeeper
# mortos diretamente, não mais um herdeiro encadeado)
df_r5 = pd.read_csv("exp_r5_heir_crash.csv")
for scenario, tag in [("buffer_dono_morto", "BufferOwnerDead"), ("modelo_dono_morto", "ModelOwnerDead")]:
    sub = df_r5[df_r5.scenario == scenario]
    lost = sub["entries_lost"].sum()
    written = sub["entries_written"].sum()
    macros[f"statExpRFive{tag}Lost"] = str(lost)
    macros[f"statExpRFive{tag}Written"] = str(written)
    macros[f"statExpRFive{tag}Pct"] = str(round(100 * lost / written))
macros["statExpRFiveTrials"] = str(sub.trial.nunique())

# Exp. Escala — overhead de checkpoint, MLP pequeno vs MLP grande
df_scale = pd.read_csv("exp_scale_checkpoint.csv")
small_row = df_scale[df_scale.model == "small"].iloc[0]
large_row = df_scale[df_scale.model == "large"].iloc[0]
macros["statScaleSmallParams"] = f"{int(small_row.param_count):,}".replace(",", "{.}")
macros["statScaleLargeParams"] = f"{int(large_row.param_count):,}".replace(",", "{.}")
# Footprint real do ring buffer (B_max=5, ver Tabela de Configuração) se
# fosse usado com o modelo grande do microbenchmark de escala — ponto de
# ancoragem real substituindo parte da extrapolação puramente linear.
macros["statScaleLargeRingBufferMB"] = texnum(large_row.bytes_per_entry * 5 / 1_000_000, 1)
macros["statScaleFactor"] = texnum(large_row.param_count / small_row.param_count, 1) + r"\times"
macros["statScaleSmallUsPerInsert"] = texnum(small_row.us_per_insert, 2)
macros["statScaleLargeUsPerInsert"] = texnum(large_row.us_per_insert, 2)
macros["statScaleTimeRatio"] = texnum(large_row.us_per_insert / small_row.us_per_insert, 1) + r"\times"

# Exp. A-Distribuído — mesma comparação async/sync do Exp. A, mas entre
# nós BEAM distribuídos de fato (containers Docker em rede real via TCP),
# não Process.sleep simulando latência dentro de uma única VM.
df_ad = pd.read_csv("../distributed_bench/results/exp_a_distributed.csv")
macros["statExpADistAsyncUps"] = texnum(df_ad["async_updates_per_s"].mean(), 1)
macros["statExpADistAsyncCI"] = texnum(ci95(df_ad["async_updates_per_s"]), 1)
macros["statExpADistSyncUps"] = texnum(df_ad["sync_updates_per_s"].mean(), 1)
macros["statExpADistSyncCI"] = texnum(ci95(df_ad["sync_updates_per_s"]), 1)
macros["statExpADistSpeedup"] = texnum(df_ad["speedup"].mean(), 2) + r"\times"
macros["statExpADistSpeedupCI"] = texnum(ci95(df_ad["speedup"]), 2)
macros["statExpADistTrials"] = str(len(df_ad))
async_gap_pct = 100 * (1 - df_ad["async_updates_per_s"].mean() / agg["async_updates_per_s"].mean())
macros["statExpADistAsyncGapPct"] = texnum(async_gap_pct, 1)

invalid = [name for name in macros if not name.isalpha()]
if invalid:
    raise ValueError(
        f"Nome(s) de macro LaTeX inválido(s) (contém dígito/símbolo — "
        f"\\newcommand exige letras apenas): {invalid}"
    )

with open("../artigo/stats_macros.tex", "w") as fh:
    fh.write("% Gerado automaticamente por results/plot_figures.py — NÃO EDITAR À MÃO.\n")
    fh.write("% Rode `python3 plot_figures.py` (dentro de results/) para regenerar.\n")
    for name in sorted(macros):
        fh.write(f"\\newcommand{{\\{name}}}{{{macros[name]}}}\n")

print(f"\n✓ artigo/stats_macros.tex ({len(macros)} macros)")

print("\n" + "═" * 60)
print("Figuras salvas em ./results/")
print("═" * 60)
