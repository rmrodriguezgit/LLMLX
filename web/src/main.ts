import { api } from "./api";
import { hideTooltip } from "./charts";
import { esc } from "./format";
import { errorBox, pill } from "./ui";
import { memoryView } from "./views/memory";
import { metricsView } from "./views/metrics";
import { profileView } from "./views/profile";
import { systemView } from "./views/system";
import type { View } from "./views/view";

const ROUTES: Record<string, { view: View; icon: string; label: string }> = {
  metricas: { view: metricsView, label: "Métricas", icon: '<path d="M4 19V10M10 19V5M16 19v-7M22 19H2"/>' },
  memoria: { view: memoryView, label: "Memoria", icon: '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10v4M11 10v4M15 10v4M19 10v4"/>' },
  perfil: { view: profileView, label: "Perfil de hardware", icon: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>' },
  sistema: { view: systemView, label: "Actualizaciones", icon: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>' },
};
const ALIASES: Record<string, string> = { metrics: "metricas", profile: "perfil", memory: "memoria", system: "sistema" };

const app = document.getElementById("app")!;
let timer: number | undefined;
let currentKey = "";
let renderSeq = 0;

function routeKey(): string {
  const raw = location.hash.replace(/^#\/?/, "").split("?")[0] ?? "";
  const key = ALIASES[raw] ?? raw;
  return key in ROUTES ? key : "metricas";
}

function shell(): void {
  app.innerHTML = `
    <aside class="sidebar">
      <div class="brand">
        <img src="logo.png" class="brand-mark" alt="" width="34" height="34">
        <div><b>LocalLLM</b><span>Gateway de inferencia</span></div>
      </div>
      <nav>${Object.entries(ROUTES)
        .map(([k, r]) => `<a href="#/${k}" data-route="${k}"><svg viewBox="0 0 24 24" aria-hidden="true">${r.icon}</svg>${esc(r.label)}</a>`)
        .join("")}</nav>
      <div class="sidebar-foot" id="foot"></div>
    </aside>
    <main>
      <header class="topbar">
        <div><h1 id="title"></h1><p id="subtitle" class="muted"></p></div>
        <div class="topbar-right"><div id="controls"></div><span id="updated" class="muted small"></span></div>
      </header>
      <div id="content" class="content"></div>
    </main>`;
}

async function renderFoot(): Promise<void> {
  const foot = document.getElementById("foot")!;
  try {
    const h = await api.health();
    foot.innerHTML = `${h.breakerOpen ? pill("critical", "Memoria baja") : pill("good", "En línea")}
      <div class="foot-model mono">${esc(h.model)}</div>
      <div class="foot-version">${esc(h.displayVersion)}</div>`;
    document.title = `LocalLLM ${h.displayVersion}`;
  } catch {
    foot.innerHTML = pill("critical", "Desconectado");
  }
}

async function render(now = false): Promise<void> {
  const key = routeKey();
  const { view } = ROUTES[key]!;
  const content = document.getElementById("content")!;
  if (key !== currentKey) {
    currentKey = key;
    content.innerHTML = `<div class="loading">Cargando…</div>`;
    document.querySelectorAll<HTMLAnchorElement>("nav a").forEach((a) => a.classList.toggle("active", a.dataset.route === key));
    document.getElementById("title")!.textContent = view.title;
    document.getElementById("subtitle")!.textContent = view.subtitle;
  }
  document.getElementById("controls")!.innerHTML = view.headerControls?.() ?? "";
  window.clearTimeout(timer);
  const seq = ++renderSeq;
  try {
    // Render off-screen, then swap: avoids flicker and keeps scroll position.
    const staging = document.createElement("div");
    staging.className = "content-inner";
    content.appendChild(staging);
    staging.style.position = "absolute";
    staging.style.visibility = "hidden";
    staging.style.width = `${content.clientWidth}px`;
    await view.render(staging);
    if (seq !== renderSeq) { staging.remove(); return; }
    staging.removeAttribute("style");
    content.replaceChildren(staging);
    document.getElementById("updated")!.textContent = `Actualizado ${new Date().toLocaleTimeString("es-MX")}`;
  } catch (err) {
    if (seq === renderSeq) content.innerHTML = errorBox(err);
  }
  void renderFoot();
  if (view.refreshMs > 0 && seq === renderSeq) {
    timer = window.setTimeout(() => {
      if (!document.hidden) void render();
      else timer = window.setTimeout(() => void render(), view.refreshMs);
    }, view.refreshMs);
  }
  void now;
}

shell();
document.getElementById("controls")!.addEventListener("click", (e) => {
  const view = ROUTES[routeKey()]!.view;
  view.onHeaderClick?.(e.target as HTMLElement, () => void render(true));
});
window.addEventListener("hashchange", () => { hideTooltip(); void render(true); });
let resizeTimer: number | undefined;
window.addEventListener("resize", () => {
  window.clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(() => void render(true), 200);
});
document.addEventListener("visibilitychange", () => { if (!document.hidden) void render(true); });
void render(true);
