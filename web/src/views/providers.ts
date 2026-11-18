import { api } from "../api";
import { esc } from "../format";
import type { ProviderInfo, ProviderKind, ProvidersInfo } from "../types";
import { card, pill } from "../ui";
import type { View } from "./view";

// Providers live in ~/Library/Application Support/LocalLLM/providers.json: saving here writes that file
// and the gateway applies it on the next request. No restart and no new .dmg needed.

const PRESETS: Record<string, { label: string; p: ProviderInfo }> = {
  claude: { label: "Claude (Anthropic)", p: { id: "claude", type: "anthropic", name: "Claude (Anthropic)", enabled: true, baseUrl: "https://api.anthropic.com", defaultModel: "claude-opus-5-5", models: ["claude-sonnet-5-5", "claude-haiku-5-5"] } },
  openai: { label: "ChatGPT (OpenAI)", p: { id: "openai", type: "openai", name: "ChatGPT (OpenAI)", enabled: true, baseUrl: "https://api.openai.com/v1", defaultModel: "gpt-5" } },
  localia: { label: "LocalIA (servidor Ubuntu)", p: { id: "localia", type: "openai", name: "LocalIA (servidor Ubuntu)", enabled: true, baseUrl: "https://192.168.4.59:8443/v1", defaultModel: "" } },
  lmstudio: { label: "LM Studio / vLLM / otro OpenAI-compatible", p: { id: "custom", type: "openai", name: "Servidor OpenAI-compatible", enabled: true, baseUrl: "http://127.0.0.1:1234/v1", defaultModel: "" } },
  openrouter: { label: "OpenRouter", p: { id: "openrouter", type: "openai", name: "OpenRouter", enabled: true, baseUrl: "https://openrouter.ai/api/v1", defaultModel: "" } },
};

const TYPE_LABEL: Record<ProviderKind, string> = {
  ollama: "Ollama (este Mac)", openai: "OpenAI-compatible", anthropic: "Anthropic (Claude)",
};

const st = {
  info: null as ProvidersInfo | null,
  draft: [] as ProviderInfo[],
  defaultProvider: "local",
  dirty: false,
  notice: "" as string,
  noticeTone: "good" as "good" | "critical" | "warning",
  tests: {} as Record<string, string>,
};

let host: HTMLElement | null = null;

export const providersView: View = {
  title: "Proveedores LLM",
  subtitle: "Ollama local, LocalIA, ChatGPT, Claude o cualquier API compatible, sin recompilar la app",
  refreshMs: 0,
  persistent: true,
  async render(root) {
    host = root;
    await reload();
    root.addEventListener("click", onClick);
    root.addEventListener("input", onInput);
    root.addEventListener("change", onInput);
  },
};

async function reload(): Promise<void> {
  const info = await api.providers();
  st.info = info;
  st.draft = info.providers.map((p) => ({ ...p, models: [...(p.models ?? [])] }));
  st.defaultProvider = info.defaultProvider;
  st.dirty = false;
  paint();
}

function paint(): void {
  if (!host || !st.info) return;
  const enabledRemote = st.draft.filter((p) => p.enabled);
  const defaultSel = `<label class="field"><span>Proveedor predeterminado</span>
      <select data-k="defaultProvider">${enabledRemote
        .map((p) => `<option value="${esc(p.id)}" ${p.id === st.defaultProvider ? "selected" : ""}>${esc(p.name)} · ${esc(p.type === "ollama" ? "modelo automático" : p.defaultModel || "?")}</option>`)
        .join("")}</select></label>
    <p class="small muted">Recibe las peticiones con <span class="mono">"model": "default"</span>, sin modelo o con un alias (gpt-4o…).
    Cualquier app puede elegir otro con <span class="mono">"model": "&lt;id&gt;/&lt;modelo&gt;"</span>, por ejemplo
    <span class="mono">claude/claude-opus-5-5</span> u <span class="mono">openai/gpt-5</span>. <span class="mono">local/…</span> fuerza Ollama.</p>`;

  const presetSel = `<div class="prov-add"><select id="prov-preset" aria-label="Plantilla">${Object.entries(PRESETS)
    .map(([k, v]) => `<option value="${k}">${esc(v.label)}</option>`).join("")}</select>
    <button type="button" class="btn btn-small" data-act="add">Añadir proveedor</button></div>`;

  const notice = st.notice ? `<p class="prov-notice">${pill(st.noticeTone, st.noticeTone === "good" ? "Listo" : "Atención")} ${esc(st.notice)}</p>` : "";
  const fileErr = st.info.error ? `<p class="prov-notice">${pill("critical", "providers.json")} ${esc(st.info.error)}</p>` : "";

  const actions = `<div class="prov-actions">
      <button type="button" class="btn" data-act="save" ${st.dirty ? "" : "disabled"}>Guardar cambios</button>
      <button type="button" class="btn btn-ghost" data-act="discard" ${st.dirty ? "" : "disabled"}>Descartar</button>
      ${st.dirty ? `<span class="small muted">Hay cambios sin guardar</span>` : ""}
    </div>`;

  host.innerHTML = `${notice}${fileErr}
    <div class="grid">
      ${card("Enrutado", defaultSel + actions, { span: 2 })}
      ${card("Archivo de configuración", `<p class="mono small break">${esc(st.info.path)}</p>
        <p class="small muted">Guardar desde aquí escribe este archivo (permisos 600). Si lo editas a mano, el cambio se aplica en la siguiente petición. Las claves nunca se muestran ni salen de este Mac, salvo hacia su proveedor.</p>${presetSel}`)}
      ${st.draft.map((p, i) => providerCard(p, i)).join("")}
    </div>`;
}

function providerCard(p: ProviderInfo, i: number): string {
  const local = p.type === "ollama";
  const status = p.enabled ? pill("good", "activo") : pill("neutral", "desactivado");
  const isDefault = p.id === st.defaultProvider ? " " + pill("warning", "predeterminado") : "";
  const test = st.tests[String(i)];
  const head = `<div class="prov-head">${status}${isDefault}
    <label class="think-toggle"><input type="checkbox" data-i="${i}" data-k="enabled" ${p.enabled ? "checked" : ""} ${local ? "disabled" : ""}> Activo</label></div>`;
  if (local) {
    return card(p.name, `${head}<p class="small muted">Motor embebido. Usa el modelo elegido en <a href="#/perfil">Perfil de hardware</a>. No se puede eliminar.</p>
      <button type="button" class="btn btn-small" data-act="test" data-i="${i}">Probar</button>${test ? `<p class="small">${test}</p>` : ""}`,
      { sub: TYPE_LABEL.ollama });
  }
  const keyPh = p.hasApiKey ? `guardada (${p.apiKeyHint ?? "••••"}) · deja vacío para conservarla` : (p.type === "anthropic" ? "sk-ant-…" : "sk-… o clave de LocalIA");
  const body = `${head}
    <div class="prov-form">
      ${field(i, "id", "Id (prefijo del modelo)", p.id, "mono")}
      ${field(i, "name", "Nombre", p.name)}
      <label class="field"><span>Tipo</span><select data-i="${i}" data-k="type">
        ${(["openai", "anthropic"] as ProviderKind[]).map((t) => `<option value="${t}" ${t === p.type ? "selected" : ""}>${TYPE_LABEL[t]}</option>`).join("")}
      </select></label>
      ${field(i, "baseUrl", "URL base", p.baseUrl ?? "", "mono")}
      <label class="field"><span>Clave API</span><input type="password" autocomplete="off" data-i="${i}" data-k="apiKey" value="${esc(p.apiKey ?? "")}" placeholder="${esc(keyPh)}"></label>
      ${field(i, "defaultModel", "Modelo predeterminado", p.defaultModel ?? "", "mono")}
      ${field(i, "models", "Otros modelos (separados por coma)", (p.models ?? []).join(", "), "mono")}
      ${field(i, "caCertPath", "Certificado CA (PEM, opcional)", p.caCertPath ?? "", "mono", "~/localia-root-ca.crt")}
      <label class="think-toggle"><input type="checkbox" data-i="${i}" data-k="allowInsecureTLS" ${p.allowInsecureTLS ? "checked" : ""}> No verificar TLS (solo pruebas en red de confianza)</label>
      ${p.hasApiKey ? `<label class="think-toggle"><input type="checkbox" data-i="${i}" data-k="clearApiKey" ${p.clearApiKey ? "checked" : ""}> Borrar la clave guardada</label>` : ""}
    </div>
    <div class="prov-actions">
      <button type="button" class="btn btn-small" data-act="test" data-i="${i}">Probar conexión</button>
      <button type="button" class="btn btn-small btn-danger" data-act="remove" data-i="${i}">Eliminar</button>
    </div>
    ${test ? `<p class="small">${test}</p>` : ""}`;
  return card(p.name || p.id, body, { sub: `${TYPE_LABEL[p.type]} · modelo: ${p.id}/${p.defaultModel || "…"}` });
}

function field(i: number, k: string, label: string, value: string, cls = "", placeholder = ""): string {
  return `<label class="field"><span>${esc(label)}</span><input type="text" spellcheck="false" class="${cls}" data-i="${i}" data-k="${k}" value="${esc(value)}" placeholder="${esc(placeholder)}"></label>`;
}

function onInput(e: Event): void {
  const t = e.target as HTMLInputElement | HTMLSelectElement;
  const k = t.dataset.k;
  if (!k) return;
  if (k === "defaultProvider") { st.defaultProvider = t.value; markDirty(e.type === "change"); return; }
  const p = st.draft[Number(t.dataset.i)];
  if (!p) return;
  const checked = (t as HTMLInputElement).checked;
  switch (k) {
    case "enabled": p.enabled = checked; break;
    case "allowInsecureTLS": p.allowInsecureTLS = checked; break;
    case "clearApiKey": p.clearApiKey = checked; break;
    case "models": p.models = t.value.split(",").map((s) => s.trim()).filter(Boolean); break;
    case "type": p.type = t.value as ProviderKind; break;
    default: (p as unknown as Record<string, string>)[k] = t.value;
  }
  // Re-render only on discrete changes so typing keeps focus.
  markDirty(e.type === "change" && (t.tagName === "SELECT" || (t as HTMLInputElement).type === "checkbox"));
}

function markDirty(repaint: boolean): void {
  st.dirty = true;
  if (repaint) { paint(); return; }
  host?.querySelectorAll<HTMLButtonElement>('[data-act="save"],[data-act="discard"]').forEach((b) => (b.disabled = false));
}

function payload(p: ProviderInfo): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(p)) {
    if (["hasApiKey", "apiKeyHint", "offeredModels"].includes(k)) continue;
    if (v === "" || v === undefined || (Array.isArray(v) && v.length === 0)) continue;
    out[k] = v;
  }
  return out;
}

async function onClick(e: Event): Promise<void> {
  const btn = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-act]");
  if (!btn || !host) return;
  const i = Number(btn.dataset.i);
  switch (btn.dataset.act) {
    case "add": {
      const key = host.querySelector<HTMLSelectElement>("#prov-preset")!.value;
      const base = structuredClone(PRESETS[key]!.p);
      let id = base.id, n = 2;
      while (st.draft.some((p) => p.id === id)) id = `${base.id}${n++}`;
      st.draft.push({ ...base, id });
      st.dirty = true; st.notice = ""; paint();
      break;
    }
    case "remove":
      if (!confirm(`¿Eliminar el proveedor ${st.draft[i]?.name}?`)) return;
      if (st.defaultProvider === st.draft[i]?.id) st.defaultProvider = "local";
      st.draft.splice(i, 1); st.dirty = true; paint();
      break;
    case "discard":
      st.notice = ""; st.tests = {}; await reload();
      break;
    case "save":
      btn.disabled = true;
      try {
        await api.saveProviders({ defaultProvider: st.defaultProvider, providers: st.draft.map(payload) });
        st.notice = "Configuración guardada y aplicada.";
        st.noticeTone = "good";
        st.tests = {};
        await reload();
      } catch (err) {
        st.notice = err instanceof Error ? err.message : String(err);
        st.noticeTone = "critical";
        paint();
      }
      break;
    case "test": {
      st.tests[String(i)] = "Probando…"; paint();
      try {
        const r = await api.testProvider(payload(st.draft[i]!));
        const list = r.models.slice(0, 12).map((m) => `<span class="mono">${esc(m)}</span>`).join(", ");
        st.tests[String(i)] = `${pill(r.ok ? "good" : "critical", r.ok ? "OK" : "Error")} ${esc(r.detail)}${list ? `<br>${list}${r.models.length > 12 ? "…" : ""}` : ""}`;
      } catch (err) {
        st.tests[String(i)] = `${pill("critical", "Error")} ${esc(err instanceof Error ? err.message : String(err))}`;
      }
      paint();
      break;
    }
  }
}
