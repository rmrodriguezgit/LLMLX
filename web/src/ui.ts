import { esc } from "./format";

export function card(title: string, body: string, opts: { sub?: string; span?: 1 | 2 | 3; id?: string; actions?: string } = {}): string {
  return `<section class="card span-${opts.span ?? 1}" ${opts.id ? `id="${opts.id}"` : ""}>
    <header class="card-head">
      <div><h3>${esc(title)}</h3>${opts.sub ? `<p class="card-sub">${esc(opts.sub)}</p>` : ""}</div>
      ${opts.actions ?? ""}
    </header>
    <div class="card-body">${body}</div>
  </section>`;
}

export function kpi(label: string, value: string, sub = "", tone: "" | "good" | "warning" | "critical" = ""): string {
  return `<div class="kpi ${tone ? `tone-${tone}` : ""}">
    <span class="kpi-label">${esc(label)}</span>
    <span class="kpi-value">${esc(value)}</span>
    <span class="kpi-sub">${esc(sub)}</span>
  </div>`;
}

export type Status = "good" | "warning" | "serious" | "critical" | "neutral";

const STATUS_ICON: Record<Status, string> = {
  good: "●", warning: "▲", serious: "◆", critical: "■", neutral: "○",
};

/** Status always carries an icon + label, never color alone. */
export function pill(status: Status, label: string): string {
  return `<span class="pill pill-${status}"><span aria-hidden="true">${STATUS_ICON[status]}</span>${esc(label)}</span>`;
}

export function table(headers: { label: string; num?: boolean }[], rows: string[][], empty = "Sin registros"): string {
  if (rows.length === 0) return `<div class="empty">${esc(empty)}</div>`;
  return `<div class="table-wrap"><table>
    <thead><tr>${headers.map((h) => `<th class="${h.num ? "num" : ""}">${esc(h.label)}</th>`).join("")}</tr></thead>
    <tbody>${rows
      .map((r) => `<tr>${r.map((c, i) => `<td class="${headers[i]?.num ? "num" : ""}">${c}</td>`).join("")}</tr>`)
      .join("")}</tbody>
  </table></div>`;
}

export function defs(items: [string, string][]): string {
  return `<dl class="defs">${items.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${v}</dd></div>`).join("")}</dl>`;
}

export function segmented(name: string, options: { value: string; label: string }[], current: string): string {
  return `<div class="segmented" role="radiogroup" aria-label="${esc(name)}">${options
    .map(
      (o) => `<button type="button" role="radio" aria-checked="${o.value === current}" data-value="${esc(o.value)}"
        class="${o.value === current ? "active" : ""}">${esc(o.label)}</button>`,
    )
    .join("")}</div>`;
}

export function errorBox(err: unknown): string {
  return `<div class="error-box">${pill("critical", "Sin conexión con LocalLLM")}<p>${esc(err instanceof Error ? err.message : String(err))}</p>
    <p class="muted">¿Está abierta la app en la barra de menú?</p></div>`;
}
