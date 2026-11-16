import { api } from "../api";
import { duration, esc, relative } from "../format";
import type { Health, UpdaterStatus } from "../types";
import { card, defs, pill, table } from "../ui";
import type { View } from "./view";

const STATE_LABEL: Record<string, string> = {
  idle: "Al día", fetching: "Buscando cambios…", pulling: "Descargando cambios…", building: "Compilando nueva versión…",
  "health-check": "Probando nueva versión…", restarting: "Reiniciando…", "git-unavailable": "git no disponible",
  "clone-failed": "Sin conexión con GitHub",
};

const OUTCOME_LABEL: Record<string, string> = {
  "up-to-date": "Sin cambios nuevos", "hot-reloaded": "Configuración aplicada al instante", rebuilding: "Compilando en segundo plano",
  rebuilt: "Nueva versión instalada", "rolled-back": "Cambio rechazado; se mantuvo la versión anterior", pulled: "Cambios descargados",
  failed: "Error al revisar", skipped: "Omitido",
};

export const systemView: View = {
  title: "Actualizaciones y sistema",
  subtitle: "Cómo se mantiene al día la app y qué versión está corriendo",
  refreshMs: 5000,
  async render(root) {
    const [h, g] = await Promise.all([api.health(), api.gitStatus()]);
    root.innerHTML = layout(h, g);
    root.querySelector<HTMLButtonElement>("#btn-sync")?.addEventListener("click", async (e) => {
      const b = e.currentTarget as HTMLButtonElement;
      b.disabled = true;
      b.textContent = "Buscando…";
      try { await api.gitSync(); } finally { void systemView.render(root); }
    });
  },
};

function layout(h: Health, g: UpdaterStatus): string {
  const busy = g.state !== "idle";
  const r = g.lastReport;
  const tone = r?.outcome === "failed" || r?.outcome === "rolled-back" ? "serious" : "good";

  const how = `<div class="steps">
      <div><span class="step-n">1</span><p><b>Revisa GitHub</b> cada 15 min (o al pulsar el botón) por cambios en
        <span class="mono">${esc((g.remote || "https://github.com/rmrodriguezgit/LLMLX.git").replace(/^https:\/\/github.com\//, "").replace(/\.git$/, ""))}</span>, rama <span class="mono">${esc(g.branch)}</span>.</p></div>
      <div><span class="step-n">2</span><p><b>Configuración</b> (modelos, límites de RAM, alias, orígenes permitidos):
        se aplica al instante, sin cortar peticiones.</p></div>
      <div><span class="step-n">3</span><p><b>Código</b>: se compila en segundo plano con los núcleos de eficiencia, se prueba,
        y la app se reemplaza sola sin cortar peticiones. Si algo falla, vuelve a la versión anterior.</p></div>
      <div><span class="step-n">4</span><p><b>Este panel</b> también se actualiza así: no hace falta reinstalar el .dmg.</p></div>
    </div>`;

  const status = `${defs([
    ["Estado", `${busy ? pill("warning", STATE_LABEL[g.state] ?? g.state) : pill("good", STATE_LABEL[g.state] ?? g.state)}`],
    ["Último cambio en GitHub", `${esc(g.headSubject ?? "—")} <span class="muted mono">${esc((g.headCommit ?? "").slice(0, 7))}</span>`],
    ["Fecha del cambio", esc(g.headDate ? new Date(g.headDate).toLocaleString("es-MX") : "—")],
    ["Última revisión", esc(relative(g.lastSyncAt))],
    ["Próxima revisión", esc(relative(g.nextSyncAt))],
    ["Resultado", r ? `${pill(tone, OUTCOME_LABEL[r.outcome] ?? r.outcome)} <span class="small muted">${esc(r.detail)}</span>` : "—"],
    ...(g.pendingCodeCommit ? [["Código pendiente", `<span class="mono">${esc(g.pendingCodeCommit.slice(0, 7))}</span> (falta Xcode Command Line Tools)`] as [string, string]] : []),
  ])}
    <button id="btn-sync" class="btn" ${busy ? "disabled" : ""}>${busy ? esc(STATE_LABEL[g.state] ?? "Ocupado") : "Buscar actualizaciones ahora"}</button>`;

  const changed = r && r.changedFiles.length
    ? table([{ label: "Archivos del último cambio" }], r.changedFiles.slice(0, 30).map((f) => [`<span class="mono small">${esc(f)}</span>`]))
    : `<div class="empty">Sin archivos cambiados en la última revisión</div>`;

  const version = defs([
    ["Versión", `<b>${esc(h.displayVersion)}</b>`],
    ["Commit en ejecución", `<span class="mono">${esc(h.commit)}</span>`],
    ["PID", String(h.pid)],
    ["Activa desde hace", esc(duration(h.uptimeSeconds))],
    ["Motor", esc(h.engine)],
    ["Repositorio local", `<span class="mono small break">${esc(g.repoPath)}</span>`],
  ]);

  const endpoints = table(
    [{ label: "Uso" }, { label: "URL" }],
    [
      ["API OpenAI (SDKs, IDEs)", `<span class="mono">${esc(location.origin)}/v1</span>`],
      ["API Ollama nativa", `<span class="mono">${esc(location.origin)}</span>`],
      ["Métricas JSON", `<a class="mono" href="/v1/metrics?window=24h">/v1/metrics</a>`],
      ["Perfil JSON", `<a class="mono" href="/v1/hardware-profile">/v1/hardware-profile</a>`],
      ["Estado", `<a class="mono" href="/health">/health</a>`],
    ],
  );

  return `<div class="grid">
    ${card("¿Para qué sirve la parte de Git?", how, { span: 2 })}
    ${card("Versión", version)}
    ${card("Estado de las actualizaciones", status, { span: 2 })}
    ${card("Último cambio recibido", changed)}
    ${card("Endpoints", endpoints, { span: 3 })}
  </div>`;
}
