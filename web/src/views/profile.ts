import { api } from "../api";
import { bindTips, stackedBar } from "../charts";
import { esc, gb } from "../format";
import type { HardwareProfile, ModelsInfo } from "../types";
import { card, defs, kpi, pill, table } from "../ui";
import type { View } from "./view";

export const profileView: View = {
  title: "Perfil de hardware",
  subtitle: "Qué detectó la app en este Mac y por qué eligió este modelo y estos parámetros",
  refreshMs: 10000,
  async render(root) {
    const [p, models] = await Promise.all([api.profile(), api.models()]);
    root.innerHTML = layout(p, models);
    bindTips(root);
    root.querySelectorAll<HTMLButtonElement>("[data-model]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const value = btn.dataset.model ?? "";
        root.querySelectorAll<HTMLButtonElement>("[data-model]").forEach((b) => (b.disabled = true));
        btn.textContent = "Aplicando…";
        try {
          await api.setModel(value === "" ? null : value);
        } finally {
          setTimeout(() => void profileView.render(root), 800);
        }
      });
    });
  },
};

function layout(p: HardwareProfile, models: ModelsInfo): string {
  const hw = p.hardware;
  const sel = p.selection;
  const est = sel.estimate;

  const kpis = `<div class="kpis">
    ${kpi("Chip", hw.chip, hw.modelIdentifier)}
    ${kpi("Memoria unificada", gb(hw.totalMemoryBytes, 0), `Metal recomienda ${gb(hw.metalRecommendedWorkingSetBytes ?? null)}`)}
    ${kpi("CPU", `${hw.performanceCores}P + ${hw.efficiencyCores}E`, `${hw.logicalCores} hilos`)}
    ${kpi("GPU", hw.gpuCores ? `${hw.gpuCores} núcleos` : "—", hw.gpuName ?? "")}
  </div>`;

  const plan = defs([
    ["Perfil", `<b>${esc(sel.profileId)}</b> <span class="muted">${esc(sel.profileDescription)}</span>`],
    ["Modelo", `<span class="mono">${esc(sel.model)}</span> ${models.override ? pill("warning", "manual") : pill("good", "automático")}`],
    ["Cuantización", esc(sel.quantization)],
    ["Contexto (num_ctx)", `${sel.numCtx.toLocaleString("es-MX")} tokens por petición`],
    ["Peticiones en paralelo", `${sel.numParallel} (OLLAMA_NUM_PARALLEL)`],
    ["KV-cache", esc(sel.kvCacheType)],
    ["Flash Attention", sel.flashAttention ? "activado" : "desactivado"],
    ["Capas en GPU (num_gpu)", sel.numGPU >= 999 ? "todas (999)" : String(sel.numGPU)],
    ["Modelos alternativos", sel.fallbackModels.map((m) => `<span class="mono">${esc(m)}</span>`).join(", ") || "—"],
  ]);

  const budget = stackedBar(
    [
      { label: "Pesos", value: est.weightsBytes, color: "var(--series-1)", display: gb(est.weightsBytes, 2) },
      { label: "KV-cache", value: est.kvCacheBytes, color: "var(--series-2)", display: gb(est.kvCacheBytes, 2) },
      { label: "Buffers", value: est.overheadBytes, color: "var(--series-4)", display: gb(est.overheadBytes, 2) },
      { label: "Margen", value: Math.max(0, est.headroomBytes), color: "var(--neutral-seg)", display: gb(est.headroomBytes, 2) },
    ],
    Math.max(est.budgetBytes, est.totalBytes),
  );

  const reasons = `<ol class="reasons">${sel.reasons.map((r) => `<li>${esc(r)}</li>`).join("")}</ol>
    ${sel.adjustments.length ? `<h4>Ajustes aplicados</h4><ul class="reasons">${sel.adjustments.map((r) => `<li>${esc(r)}</li>`).join("")}</ul>` : ""}`;

  const installed = models.installed;
  const modelRows = [
    [`<b>Automático</b> <span class="muted">(${esc(models.auto)})</span>`, "—", modelButton("", models.override == null)],
    ...installed.map((m) => [
      `<span class="mono">${esc(m.name)}</span>${models.loaded.some((l) => l.name === m.name) ? " " + pill("good", "en memoria") : ""}`,
      gb(m.sizeBytes, 2),
      modelButton(m.name, models.override === m.name),
    ]),
  ];
  const picker = `<p class="muted small">Modelo que reciben las peticiones con <span class="mono">"model": "default"</span>, <span class="mono">"local"</span> o un alias (gpt-4o…). Si una app pide un modelo instalado concreto, se respeta.</p>
    ${table([{ label: "Modelo" }, { label: "Tamaño", num: true }, { label: "" }], modelRows)}
    ${models.lastUsed && models.lastUsed !== models.active ? `<p class="small">${pill("warning", "Aviso")} La última petición usó <span class="mono">${esc(models.lastUsed)}</span> porque la app lo pidió por nombre.</p>` : ""}`;

  const env = table(
    [{ label: "Variable" }, { label: "Valor" }],
    Object.entries(p.ollamaEnvironment).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [`<span class="mono">${esc(k)}</span>`, `<span class="mono">${esc(v)}</span>`]),
  );

  return `${kpis}
    <div class="grid">
      ${card("Configuración elegida", plan, { span: 2, sub: p.summary })}
      ${card("Presupuesto de memoria Metal", budget + `<p class="small muted">Estimación: ${gb(est.totalBytes, 2)} de ${gb(est.budgetBytes, 2)} disponibles para la GPU. Si no cabe, se reduce el contexto, luego el paralelismo y por último se baja de perfil.</p>`)}
      ${card("Por qué se eligió así", reasons, { span: 2 })}
      ${card("Elegir modelo", picker, { span: 1 })}
      ${card("Variables de entorno de Ollama", env, { span: 2, sub: "Calculadas a partir del perfil" })}
      ${card("Origen de la configuración", `<p class="mono small break">${esc(p.configSource)}</p><p class="small muted">Este archivo viene del repositorio de GitHub y se recarga solo cuando cambia.</p>`)}
    </div>`;
}

function modelButton(value: string, active: boolean): string {
  return active
    ? `<span class="pill pill-good">✓ activo</span>`
    : `<button class="btn btn-small" data-model="${esc(value)}">Usar</button>`;
}
