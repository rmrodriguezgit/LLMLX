import { api } from "../api";
import { barList, bindTips, lineChart } from "../charts";
import { compact, esc, fixed, int, ms, pct, timeLabel } from "../format";
import type { Metrics, SeriesPoint, Timeseries } from "../types";
import { card, kpi, pill, segmented, table } from "../ui";
import type { View } from "./view";

const WINDOWS = [
  { value: "1h", label: "1 h" },
  { value: "24h", label: "24 h" },
  { value: "7d", label: "7 días" },
  { value: "30d", label: "30 días" },
];

let windowSel = (() => {
  try { return localStorage.getItem("llm.window") ?? "24h"; } catch { return "24h"; }
})();

/** Fills empty buckets so time is continuous (counts → 0, averages → gap). */
function densify(ts: Timeseries): SeriesPoint[] {
  const byT = new Map(ts.points.map((p) => [p.t, p]));
  const start = Math.floor(ts.from / ts.bucketSeconds) * ts.bucketSeconds;
  const out: SeriesPoint[] = [];
  for (let t = start; t <= ts.to; t += ts.bucketSeconds) {
    out.push(byT.get(t) ?? { t, requests: 0, failed: 0, prompt_tokens: 0, completion_tokens: 0, tokens_per_sec: null, ttft_ms: null });
  }
  return out;
}

export const metricsView: View = {
  title: "Métricas",
  subtitle: "Peticiones, tokens y latencia de todas las apps que usan el gateway",
  refreshMs: 5000,
  headerControls: () => segmented("Periodo", WINDOWS, windowSel),
  onHeaderClick(target, rerender) {
    const v = target.closest<HTMLElement>("[data-value]")?.dataset.value;
    if (v && v !== windowSel) {
      windowSel = v;
      try { localStorage.setItem("llm.window", v); } catch { /* private mode */ }
      rerender(true);
    }
  },
  async render(root) {
    const [m, ts] = await Promise.all([api.metrics(windowSel), api.timeseries(windowSel)]);
    root.innerHTML = layout(m);
    const pts = densify(ts);
    const xs = pts.map((p) => p.t);
    const xl = (t: number) => timeLabel(t, ts.bucketSeconds, ts.to - ts.from);
    lineChart(root.querySelector<HTMLElement>("#ch-tokens")!, {
      xs, xLabel: xl, yFormat: (v) => compact(v), area: false,
      series: [
        { name: "Tokens de salida", color: "var(--series-1)", values: pts.map((p) => p.completion_tokens) },
        { name: "Tokens de entrada", color: "var(--series-2)", values: pts.map((p) => p.prompt_tokens) },
      ],
    });
    lineChart(root.querySelector<HTMLElement>("#ch-requests")!, {
      xs, xLabel: xl, yFormat: (v) => int(v), area: true,
      series: [{ name: "Peticiones", color: "var(--series-1)", values: pts.map((p) => p.requests) }],
    });
    lineChart(root.querySelector<HTMLElement>("#ch-tps")!, {
      xs, xLabel: xl, yFormat: (v) => fixed(v, 1), height: 180,
      series: [{ name: "tok/s", color: "var(--series-3)", values: pts.map((p) => p.tokens_per_sec) }],
      emptyText: "Aún no hay peticiones con velocidad medida",
    });
    lineChart(root.querySelector<HTMLElement>("#ch-ttft")!, {
      xs, xLabel: xl, yFormat: (v) => ms(v), height: 180,
      series: [{ name: "TTFT", color: "var(--series-2)", values: pts.map((p) => p.ttft_ms) }],
      emptyText: "Aún no hay peticiones con TTFT medido",
    });
    bindTips(root);
  },
};

function layout(m: Metrics): string {
  const t = m.totals;
  const ok = t.ok ?? 0;
  const failed = (t.errors ?? 0) + (t.rejected ?? 0);
  const live = m.live;

  const kpis = `<div class="kpis">
    ${kpi("Peticiones", int(t.requests), `${pct(ok, t.requests)} correctas`)}
    ${kpi("Tokens de entrada", compact(t.prompt_tokens), "prompt (contexto)")}
    ${kpi("Tokens de salida", compact(t.completion_tokens), "generados")}
    ${kpi("Velocidad", fixed(t.tokens_per_sec_p50, 1, " tok/s"), `p95 ${fixed(t.tokens_per_sec_p95, 1)} · máx ${fixed(t.max_tokens_per_sec, 1)}`)}
    ${kpi("TTFT (mediana)", ms(t.ttft_ms_p50), `p95 ${ms(t.ttft_ms_p95)} · cola ${ms(t.avg_queue_ms)}`)}
    ${kpi("Rechazadas / errores", `${int(t.rejected ?? 0)} / ${int(t.errors ?? 0)}`, failed ? "429 memoria/cola · 5xx motor" : "ninguna", failed ? "warning" : "good")}
  </div>`;

  const liveBar = `<div class="live-strip">
    ${live.breakerOpen ? pill("critical", "Circuit breaker abierto") : pill("good", "Memoria OK")}
    <span><b>${int(live.inFlight)}</b>/${int(live.capacity)} en curso</span>
    <span><b>${int(live.queued)}</b> en cola</span>
    <span>Modelo <b>${esc(live.model)}</b></span>
    <span class="muted">${esc(live.engine)}</span>
  </div>`;

  const clientItems = m.byClient.slice(0, 10).map((c) => ({
    label: c.client_app,
    value: c.total_tokens,
    display: compact(c.total_tokens),
    tip: `<div class="tip-title">${esc(c.client_app)}</div>
      <div class="tip-row"><span>Peticiones</span><b>${int(c.requests)}</b></div>
      <div class="tip-row"><span>Entrada / salida</span><b>${compact(c.prompt_tokens)} / ${compact(c.completion_tokens)}</b></div>
      <div class="tip-row"><span>Velocidad media</span><b>${fixed(c.avg_tokens_per_sec, 1, " tok/s")}</b></div>
      <div class="tip-row"><span>TTFT medio</span><b>${ms(c.avg_ttft_ms)}</b></div>`,
  }));
  const modelItems = m.byModel.slice(0, 10).map((c) => ({
    label: c.model, value: c.total_tokens, display: compact(c.total_tokens),
    tip: `<div class="tip-title">${esc(c.model)}</div>
      <div class="tip-row"><span>Peticiones</span><b>${int(c.requests)}</b></div>
      <div class="tip-row"><span>Velocidad media</span><b>${fixed(c.avg_tokens_per_sec, 1, " tok/s")}</b></div>`,
  }));

  const clientTable = table(
    [{ label: "App" }, { label: "Peticiones", num: true }, { label: "Entrada", num: true }, { label: "Salida", num: true },
     { label: "tok/s", num: true }, { label: "TTFT", num: true }, { label: "Fallidas", num: true }],
    m.byClient.map((c) => [esc(c.client_app), int(c.requests), compact(c.prompt_tokens), compact(c.completion_tokens),
      fixed(c.avg_tokens_per_sec, 1), ms(c.avg_ttft_ms), int((c.errors ?? 0) + (c.rejected ?? 0))]),
    "Ninguna app ha hecho peticiones en este periodo",
  );

  const recent = table(
    [{ label: "Hora" }, { label: "App" }, { label: "Endpoint" }, { label: "Modelo" }, { label: "Estado" },
     { label: "Entrada", num: true }, { label: "Salida", num: true }, { label: "TTFT", num: true }, { label: "tok/s", num: true }],
    m.recent.map((r) => [
      `<span class="mono">${esc(r.time.slice(11))}</span>`, esc(r.client_app), `<span class="mono">${esc(r.endpoint)}${r.stream ? " ⇢" : ""}</span>`,
      esc(r.model), statusCell(r.status, r.error), int(r.prompt_tokens), int(r.completion_tokens), ms(r.ttft_ms), fixed(r.tokens_per_sec, 1),
    ]),
    "Sin peticiones registradas",
  );

  const incidents = table(
    [{ label: "Hora" }, { label: "Tipo" }, { label: "Detalle" }],
    m.incidents.slice(0, 12).map((i) => [`<span class="mono">${esc(i.time.slice(5))}</span>`, incidentPill(i.kind), `<span class="small">${esc(i.detail)}</span>`]),
    "Sin incidentes",
  );

  return `${liveBar}${kpis}
    <div class="grid">
      ${card("Tokens procesados", '<div id="ch-tokens" class="chart-host"></div>', { span: 2, sub: "Por intervalo de tiempo" })}
      ${card("Peticiones", '<div id="ch-requests" class="chart-host"></div>', { sub: "Por intervalo" })}
      ${card("Velocidad de generación", '<div id="ch-tps" class="chart-host"></div>', { sub: "tok/s promedio por intervalo" })}
      ${card("Tiempo al primer token", '<div id="ch-ttft" class="chart-host"></div>', { sub: "TTFT promedio por intervalo" })}
      ${card("Uso por modelo", barList(modelItems, "var(--series-1)", "Sin uso"), { sub: "Tokens totales" })}
      ${card("Uso por aplicación", barList(clientItems, "var(--series-1)", "Sin uso"), { sub: "Tokens totales (cabecera X-Client-App o User-Agent)" })}
      ${card("Detalle por aplicación", clientTable, { span: 2 })}
      ${card("Últimas peticiones", recent, { span: 3 })}
      ${card("Incidentes", incidents, { span: 3, sub: "Memoria, actualizaciones y cambios de modelo" })}
    </div>`;
}

function statusCell(status: number, error: string | null): string {
  if (status >= 200 && status < 300) return pill("good", String(status));
  const tip = error ? ` data-tip="${esc(esc(error))}"` : "";
  if (status === 429 || status === 503) return `<span${tip}>${pill("warning", String(status))}</span>`;
  if (status === 499) return `<span${tip}>${pill("neutral", "cancelada")}</span>`;
  return `<span${tip}>${pill("critical", String(status))}</span>`;
}

function incidentPill(kind: string): string {
  if (kind.includes("open") || kind.includes("rollback") || kind.includes("failed")) return pill("serious", kind);
  if (kind.includes("closed") || kind === "handoff") return pill("good", kind);
  return pill("neutral", kind);
}
