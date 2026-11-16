import { esc } from "./format";

// Hand-rolled SVG/HTML charts: no runtime dependencies, theme via CSS custom properties.

export interface LineSeries {
  name: string;
  color: string; // CSS color or var(--series-n)
  values: (number | null)[];
}

export interface LineChartOptions {
  xs: number[];
  series: LineSeries[];
  xLabel: (x: number) => string;
  yFormat: (v: number) => string;
  height?: number;
  area?: boolean;
  yMin?: number;
  threshold?: { value: number; label: string };
  emptyText?: string;
}

const tooltip = (() => {
  let el: HTMLDivElement | null = null;
  return () => {
    if (!el) {
      el = document.createElement("div");
      el.className = "tooltip";
      el.setAttribute("role", "tooltip");
      document.body.appendChild(el);
    }
    return el;
  };
})();

export function showTooltip(html: string, clientX: number, clientY: number): void {
  const t = tooltip();
  t.innerHTML = html;
  t.style.display = "block";
  const pad = 14;
  const { width, height } = t.getBoundingClientRect();
  let x = clientX + pad;
  let y = clientY + pad;
  if (x + width > window.innerWidth - 8) x = clientX - width - pad;
  if (y + height > window.innerHeight - 8) y = clientY - height - pad;
  t.style.transform = `translate(${Math.max(8, x)}px, ${Math.max(8, y)}px)`;
}

export function hideTooltip(): void {
  tooltip().style.display = "none";
}

/** Attaches the shared tooltip to every element matching `[data-tip]` inside root. */
export function bindTips(root: HTMLElement): void {
  root.querySelectorAll<HTMLElement>("[data-tip]").forEach((el) => {
    el.addEventListener("mousemove", (e) => showTooltip(el.dataset.tip ?? "", e.clientX, e.clientY));
    el.addEventListener("mouseleave", hideTooltip);
  });
}

function niceMax(v: number): number {
  if (v <= 0) return 1;
  const exp = Math.pow(10, Math.floor(Math.log10(v)));
  const f = v / exp;
  const nice = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10;
  return nice * exp;
}

export function lineChart(host: HTMLElement, o: LineChartOptions): void {
  const width = Math.max(280, host.clientWidth);
  const height = o.height ?? 200;
  const m = { top: 14, right: 14, bottom: 26, left: 52 };
  const iw = width - m.left - m.right;
  const ih = height - m.top - m.bottom;
  const n = o.xs.length;

  const all = o.series.flatMap((s) => s.values).filter((v): v is number => v != null && Number.isFinite(v));
  if (n === 0 || all.length === 0) {
    host.innerHTML = `<div class="empty" style="height:${height}px">${esc(o.emptyText ?? "Sin datos en este periodo")}</div>`;
    return;
  }
  const yMin = o.yMin ?? 0;
  const yMax = niceMax(Math.max(...all, o.threshold?.value ?? 0, yMin + 1e-9) * 1.08);
  const x = (i: number) => m.left + (n === 1 ? iw / 2 : (i / (n - 1)) * iw);
  const y = (v: number) => m.top + ih - ((v - yMin) / (yMax - yMin)) * ih;

  const grid: string[] = [];
  for (let k = 0; k <= 4; k++) {
    const v = yMin + ((yMax - yMin) * k) / 4;
    const yy = y(v);
    grid.push(`<line class="grid" x1="${m.left}" x2="${width - m.right}" y1="${yy}" y2="${yy}"/>`);
    grid.push(`<text class="axis" x="${m.left - 8}" y="${yy + 4}" text-anchor="end">${esc(o.yFormat(v))}</text>`);
  }
  const tickCount = Math.min(n, Math.max(2, Math.floor(iw / 90)));
  for (let k = 0; k < tickCount; k++) {
    const i = tickCount === 1 ? 0 : Math.round((k * (n - 1)) / (tickCount - 1));
    const xx = x(i);
    const anchor = k === 0 ? "start" : k === tickCount - 1 ? "end" : "middle";
    grid.push(`<text class="axis" x="${xx}" y="${height - 6}" text-anchor="${anchor}">${esc(o.xLabel(o.xs[i] ?? 0))}</text>`);
  }

  const paths: string[] = [];
  for (const s of o.series) {
    let d = "";
    let areaD = "";
    let segStart = -1;
    const flushArea = (end: number) => {
      if (segStart >= 0 && o.area) {
        areaD += `L${x(end)},${y(yMin)}L${x(segStart)},${y(yMin)}Z`;
      }
    };
    s.values.forEach((v, i) => {
      if (v == null) {
        flushArea(i - 1);
        segStart = -1;
        return;
      }
      if (segStart < 0) {
        segStart = i;
        d += `M${x(i)},${y(v)}`;
        if (o.area) areaD += `M${x(i)},${y(v)}`;
      } else {
        d += `L${x(i)},${y(v)}`;
        if (o.area) areaD += `L${x(i)},${y(v)}`;
      }
    });
    flushArea(s.values.length - 1);
    if (o.area) paths.push(`<path d="${areaD}" fill="${s.color}" opacity="0.14"/>`);
    paths.push(`<path d="${d}" fill="none" stroke="${s.color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`);
    // Isolated points (neighbours null) are invisible as lines: draw them as dots.
    s.values.forEach((v, i) => {
      if (v != null && s.values[i - 1] == null && s.values[i + 1] == null) {
        paths.push(`<circle cx="${x(i)}" cy="${y(v)}" r="3" fill="${s.color}"/>`);
      }
    });
  }

  let thresholdSvg = "";
  if (o.threshold) {
    const ty = y(o.threshold.value);
    thresholdSvg = `<line class="threshold" x1="${m.left}" x2="${width - m.right}" y1="${ty}" y2="${ty}"/>
      <text class="threshold-label" x="${width - m.right}" y="${ty - 6}" text-anchor="end">${esc(o.threshold.label)}</text>`;
  }

  host.innerHTML = `
    <svg class="chart" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img">
      ${grid.join("")}
      ${thresholdSvg}
      ${paths.join("")}
      <line class="crosshair" x1="0" x2="0" y1="${m.top}" y2="${m.top + ih}" visibility="hidden"/>
      <g class="hover-dots"></g>
      <rect class="hit" x="${m.left}" y="${m.top}" width="${iw}" height="${ih}" fill="transparent"/>
    </svg>
    ${o.series.length > 1 ? `<div class="legend">${o.series.map((s) => `<span><i style="background:${s.color}"></i>${esc(s.name)}</span>`).join("")}</div>` : ""}`;

  const svg = host.querySelector("svg")!;
  const hit = svg.querySelector<SVGRectElement>(".hit")!;
  const cross = svg.querySelector<SVGLineElement>(".crosshair")!;
  const dots = svg.querySelector<SVGGElement>(".hover-dots")!;
  hit.addEventListener("mousemove", (e) => {
    const rect = svg.getBoundingClientRect();
    const px = e.clientX - rect.left;
    const i = n === 1 ? 0 : Math.max(0, Math.min(n - 1, Math.round(((px - m.left) / iw) * (n - 1))));
    const xx = x(i);
    cross.setAttribute("x1", String(xx));
    cross.setAttribute("x2", String(xx));
    cross.setAttribute("visibility", "visible");
    dots.innerHTML = o.series
      .map((s) => {
        const v = s.values[i];
        return v == null ? "" : `<circle cx="${xx}" cy="${y(v)}" r="4.5" fill="${s.color}" class="hover-dot"/>`;
      })
      .join("");
    const rows = o.series
      .map((s) => {
        const v = s.values[i];
        return `<div class="tip-row"><i style="background:${s.color}"></i><span>${esc(s.name)}</span><b>${v == null ? "—" : esc(o.yFormat(v))}</b></div>`;
      })
      .join("");
    showTooltip(`<div class="tip-title">${esc(o.xLabel(o.xs[i] ?? 0))}</div>${rows}`, e.clientX, e.clientY);
  });
  hit.addEventListener("mouseleave", () => {
    cross.setAttribute("visibility", "hidden");
    dots.innerHTML = "";
    hideTooltip();
  });
}

export interface BarItem {
  label: string;
  value: number;
  display: string;
  tip?: string; // pre-escaped HTML
}

/** Horizontal bar list: label · bar · value. Single measure, single hue. */
export function barList(items: BarItem[], color = "var(--series-1)", empty = "Sin datos"): string {
  if (items.length === 0) return `<div class="empty">${esc(empty)}</div>`;
  const max = Math.max(...items.map((i) => i.value), 1);
  return `<div class="barlist">${items
    .map(
      (i) => `<div class="barlist-row" ${i.tip ? `data-tip="${esc(i.tip)}"` : ""}>
        <span class="barlist-label" title="${esc(i.label)}">${esc(i.label)}</span>
        <span class="barlist-track"><span class="barlist-fill" style="width:${Math.max(1.5, (i.value / max) * 100)}%;background:${color}"></span></span>
        <span class="barlist-value">${esc(i.display)}</span>
      </div>`,
    )
    .join("")}</div>`;
}

export interface StackSegment {
  label: string;
  value: number;
  color: string;
  display: string;
}

/** Part-to-whole bar with 2px surface gaps, optional marker (e.g. safety threshold). */
export function stackedBar(segments: StackSegment[], total: number, marker?: { at: number; label: string }): string {
  const visible = segments.filter((s) => s.value > 0);
  return `<div class="stack-wrap">
    <div class="stack">
      ${visible
        .map(
          (s) => `<span class="stack-seg" style="flex:${s.value / total} 1 0;background:${s.color}"
            data-tip="${esc(`<div class="tip-title">${esc(s.label)}</div><div class="tip-row"><b>${esc(s.display)}</b></div>`)}"></span>`,
        )
        .join("")}
      ${marker ? `<span class="stack-marker" style="left:${Math.min(100, (marker.at / total) * 100)}%" data-tip="${esc(marker.label)}"></span>` : ""}
    </div>
    <div class="legend">${segments
      .map((s) => `<span><i style="background:${s.color}"></i>${esc(s.label)} <b>${esc(s.display)}</b></span>`)
      .join("")}</div>
  </div>`;
}
