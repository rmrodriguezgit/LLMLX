import { api } from "../api";
import { bindTips, lineChart, stackedBar } from "../charts";
import { esc, gb, GiB, relative } from "../format";
import type { MemoryInfo } from "../types";
import { card, defs, kpi, pill, table } from "../ui";
import type { View } from "./view";

export const memoryView: View = {
  title: "Memoria",
  subtitle: "Memoria unificada en tiempo real y protección contra swap",
  refreshMs: 2000,
  async render(root) {
    const info = await api.memory();
    root.innerHTML = layout(info);
    const h = info.history;
    lineChart(root.querySelector<HTMLElement>("#ch-free")!, {
      xs: h.map((p) => p.t),
      xLabel: (t) => new Date(t * 1000).toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit", second: "2-digit" }),
      yFormat: (v) => `${(v / GiB).toFixed(1)} GB`,
      area: true,
      height: 220,
      series: [{ name: "RAM disponible", color: "var(--series-3)", values: h.map((p) => p.available) }],
      threshold: { value: info.now.thresholdBytes, label: `Umbral del breaker ${gb(info.now.thresholdBytes)}` },
      emptyText: "Recolectando muestras…",
    });
    lineChart(root.querySelector<HTMLElement>("#ch-swap")!, {
      xs: h.map((p) => p.t),
      xLabel: (t) => new Date(t * 1000).toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" }),
      yFormat: (v) => `${(v / GiB).toFixed(2)} GB`,
      height: 160,
      series: [{ name: "Swap usado", color: "var(--series-2)", values: h.map((p) => p.swap) }],
      emptyText: "Recolectando muestras…",
    });
    bindTips(root);
  },
};

function layout(info: MemoryInfo): string {
  const s = info.now;
  const total = s.totalBytes;
  const used = Math.max(0, total - s.availableBytes);
  const modelBytes = info.weightsBytes + info.kvCacheBytes;
  const others = Math.max(0, used - modelBytes);
  const headroom = s.availableBytes - s.thresholdBytes;
  const breakerTone = s.breakerOpen ? "critical" : headroom < GiB ? "warning" : "good";

  const kpis = `<div class="kpis">
    ${kpi("Disponible", gb(s.availableBytes), `margen ${gb(headroom)} sobre el umbral`, breakerTone)}
    ${kpi("Modelo en memoria", gb(modelBytes), info.loadedModels.length ? info.loadedModels.map((m) => m.name).join(", ") : "ninguno cargado")}
    ${kpi("Swap usado", gb(s.swapUsedBytes, 2), "acumulado por macOS")}
    ${kpi("Presión del kernel", pressureLabel(s.pressure), "DispatchSource memory pressure", s.pressure === "normal" ? "good" : s.pressure === "warning" ? "warning" : "critical")}
  </div>`;

  const breaker = s.breakerOpen
    ? `${pill("critical", "Circuit breaker ABIERTO")}<p>Las nuevas peticiones reciben <b>429 Retry-After</b> hasta que la RAM disponible supere ${gb(s.thresholdBytes + 0.7 * GiB)} durante 5 s. Si no hay generaciones en curso, el modelo se descarga para liberar pesos y KV-cache.</p>`
    : `${pill("good", "Circuit breaker cerrado")}<p>Se abre automáticamente si la RAM disponible baja de <b>${gb(s.thresholdBytes)}</b> o si macOS reporta presión crítica, antes de que el sistema tenga que usar swap.</p>`;

  const composition = stackedBar(
    [
      { label: "Pesos del modelo", value: info.weightsBytes, color: "var(--series-1)", display: gb(info.weightsBytes) },
      { label: "KV-cache", value: info.kvCacheBytes, color: "var(--series-2)", display: gb(info.kvCacheBytes) },
      { label: "macOS y otras apps", value: others, color: "var(--neutral-seg)", display: gb(others) },
      { label: "Disponible", value: s.availableBytes, color: "var(--series-3)", display: gb(s.availableBytes) },
    ],
    total,
    { at: total - s.thresholdBytes, label: `Umbral del breaker: el segmento “Disponible” no debe quedar a la derecha de esta línea (${gb(s.thresholdBytes)})` },
  );

  const vm = defs([
    ["Total", gb(total)],
    ["Wired (kernel + Metal)", gb(s.wiredBytes)],
    ["Activa", gb(s.activeBytes)],
    ["Inactiva", gb(s.inactiveBytes)],
    ["Comprimida", gb(s.compressedBytes)],
    ["Caché de archivos", gb(s.fileBackedBytes)],
    ["Libre", gb(s.freeBytes)],
    ["Purgable", gb(s.purgeableBytes)],
  ]);

  const models = table(
    [{ label: "Modelo" }, { label: "Total residente", num: true }, { label: "Pesos", num: true }, { label: "KV-cache", num: true },
     { label: "Contexto", num: true }, { label: "Se descarga" }],
    info.loadedModels.map((m) => [esc(m.name), gb(m.sizeBytes, 2), gb(m.weightsBytes, 2), gb(m.kvCacheBytes, 2),
      m.contextLength ? String(m.contextLength) : "—", esc(relative(m.expiresAt))]),
    "Ningún modelo cargado. Se carga automáticamente con la siguiente petición.",
  );

  const est = info.plan.estimate;
  const plan = stackedBar(
    [
      { label: "Pesos (estimado)", value: est.weightsBytes, color: "var(--series-1)", display: gb(est.weightsBytes, 2) },
      { label: "KV-cache (estimado)", value: est.kvCacheBytes, color: "var(--series-2)", display: gb(est.kvCacheBytes, 2) },
      { label: "Buffers de cómputo", value: est.overheadBytes, color: "var(--series-4)", display: gb(est.overheadBytes, 2) },
      { label: "Margen libre", value: Math.max(0, est.headroomBytes), color: "var(--neutral-seg)", display: gb(est.headroomBytes, 2) },
    ],
    Math.max(est.budgetBytes, est.totalBytes),
  );

  return `${kpis}
    <div class="grid">
      ${card("Composición de la memoria unificada", composition + `<div class="note">${breaker}</div>`, { span: 2 })}
      ${card("Detalle Mach VM", vm, { sub: "host_statistics64" })}
      ${card("RAM disponible — últimos 15 min", '<div id="ch-free" class="chart-host"></div>', { span: 2, sub: "Muestreo cada 2 s" })}
      ${card("Swap", '<div id="ch-swap" class="chart-host"></div>', { sub: "Debe mantenerse plano" })}
      ${card("Modelos cargados en Metal", models, { span: 2 })}
      ${card(`Plan de memoria de ${info.plan.model}`, plan, { sub: `Presupuesto Metal ${gb(info.plan.budgetBytes, 2)}` })}
    </div>`;
}

function pressureLabel(p: string): string {
  return p === "normal" ? "Normal" : p === "warning" ? "Advertencia" : p === "critical" ? "Crítica" : p;
}
