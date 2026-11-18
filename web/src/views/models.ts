import { api } from "../api";
import { esc, gb } from "../format";
import type { ModelsInfo, Provider, ProviderInput } from "../types";
import { card, pill, table } from "../ui";
import type { View } from "./view";

/** Common OpenAI-compatible endpoints. Model lists are only suggestions: "Descubrir" asks the API. */
const PRESETS: { id: string; name: string; baseURL: string; models: string[]; keyless?: boolean }[] = [
  { id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", models: ["gpt-4o-mini", "gpt-4.1"] },
  { id: "anthropic", name: "Anthropic (Claude)", baseURL: "https://api.anthropic.com/v1", models: ["claude-sonnet-5-5", "claude-haiku-5-5"] },
  { id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", models: ["gemini-2.5-flash"] },
  { id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", models: [] },
  { id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", models: ["llama-3.3-70b-versatile"] },
  { id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", models: ["mistral-small-latest"] },
  { id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", models: ["deepseek-chat"] },
  { id: "xai", name: "xAI (Grok)", baseURL: "https://api.x.ai/v1", models: [] },
  { id: "lmstudio", name: "LM Studio (este Mac)", baseURL: "http://127.0.0.1:1234/v1", models: [], keyless: true },
];

let editing: Provider | null = null;
let notice: { tone: "good" | "critical"; text: string } | null = null;

export const modelsView: View = {
  title: "Modelos y APIs",
  subtitle: "El modelo activo es el que reciben todas las apps que piden \"default\", \"local\" o un alias",
  refreshMs: 0,
  persistent: true,
  async render(root) {
    const [models, prov] = await Promise.all([api.models(), api.providers()]);
    root.innerHTML = layout(models, prov.providers);
    bind(root, prov.providers);
  },
};

function rerender(root: HTMLElement): void { void modelsView.render(root); }

function useButton(value: string, active: boolean, disabled = false): string {
  if (active) return pill("good", "activo");
  return `<button class="btn btn-small" data-use="${esc(value)}" ${disabled ? "disabled title=\"Falta la API key\"" : ""}>Usar</button>`;
}

function layout(m: ModelsInfo, providers: Provider[]): string {
  const activeKind = m.activeIsRemote ? pill("warning", "API remota") : m.override ? pill("neutral", "local · manual") : pill("good", "local · automático");
  const summary = `<p class="big mono">${esc(m.active)}</p><p>${activeKind}</p>
    <p class="small muted">Las apps conectadas a <span class="mono">http://127.0.0.1:11500/v1</span> (OpenAI) o <span class="mono">http://127.0.0.1:11500</span> (Ollama) usan este modelo sin cambiar nada.
    Una app puede pedir otro por nombre: un modelo instalado (<span class="mono">qwen3:8b</span>) o <span class="mono">proveedor/modelo</span> (<span class="mono">openai/gpt-4o-mini</span>).</p>
    ${m.activeIsRemote ? `<p class="small muted">El motor local queda en <span class="mono">${esc(m.localModel)}</span> y se libera de la memoria mientras usas la API.</p>` : ""}`;

  const localRows = [
    [`<b>Automático</b> <span class="muted">(${esc(m.auto)})</span>`, "—", useButton("", m.override == null)],
    ...m.installed.map((x) => [
      `<span class="mono">${esc(x.name)}</span>${m.loaded.some((l) => l.name === x.name) ? " " + pill("good", "en memoria") : ""}`,
      gb(x.sizeBytes, 2),
      useButton(x.name, m.override === x.name),
    ]),
  ];

  const remoteRows = providers.flatMap((p) =>
    p.models.map((model) => {
      const full = `${p.id}/${model}`;
      return [`<span class="mono">${esc(full)}</span>`, esc(p.name), useButton(full, m.override === full, !p.enabled)];
    }),
  );

  const providerRows = providers.map((p) => [
    `<b>${esc(p.name)}</b><br><span class="mono small muted">${esc(p.id)}</span>`,
    `<span class="mono small break">${esc(p.baseURL)}</span>`,
    p.hasKey ? pill("good", `clave ${p.keyHint ?? ""}`) : pill("warning", "sin clave"),
    p.enabled ? pill("good", "activo") : pill("neutral", "desactivado"),
    `<button class="btn btn-small" data-edit="${esc(p.id)}">Editar</button>
     <button class="btn btn-small" data-discover="${esc(p.id)}">Descubrir modelos</button>
     <button class="btn btn-small" data-delete="${esc(p.id)}">Eliminar</button>`,
  ]);

  const e = editing;
  const form = `<form class="provider-form" id="provider-form" autocomplete="off">
      <label>Plantilla
        <select id="pf-preset"><option value="">— Elegir servicio —</option>${PRESETS.map((p) => `<option value="${p.id}">${esc(p.name)}</option>`).join("")}</select>
      </label>
      <label>ID (prefijo del modelo)<input name="id" required pattern="[a-z0-9][a-z0-9_-]{0,31}" value="${esc(e?.id ?? "")}" ${e ? "readonly" : ""} placeholder="openai"></label>
      <label>Nombre<input name="name" value="${esc(e?.name ?? "")}" placeholder="OpenAI"></label>
      <label class="wide">Base URL (compatible con OpenAI)<input name="baseURL" required value="${esc(e?.baseURL ?? "")}" placeholder="https://api.openai.com/v1"></label>
      <label class="wide">API key <span class="muted">${e?.hasKey ? "(vacío = conservar la actual)" : ""}</span><input name="apiKey" type="password" placeholder="${e?.hasKey ? "••••••" : "sk-…"}"></label>
      <label class="wide">…o variable de entorno con la clave <span class="muted">(opcional)</span><input name="apiKeyEnv" value="${esc(e?.apiKeyEnv ?? "")}" placeholder="OPENAI_API_KEY"></label>
      <label class="wide">Modelos (uno por línea o separados por coma)<textarea name="models" rows="3" placeholder="gpt-4o-mini">${esc((e?.models ?? []).join("\n"))}</textarea></label>
      <label class="check"><input type="checkbox" name="enabled" ${e?.enabled === false ? "" : "checked"}> Habilitado</label>
      <div class="wide row">
        <button class="btn" type="submit">${e ? "Guardar cambios" : "Añadir proveedor"}</button>
        ${e ? `<button class="btn btn-small" type="button" data-cancel>Cancelar</button>` : ""}
      </div>
      <p class="wide small muted">La clave se guarda solo en este Mac (<span class="mono">~/Library/Application Support/LocalLLM/providers.json</span>, permisos 600). Nunca se sube a Git ni se devuelve por la API.</p>
    </form>`;

  return `${notice ? `<div class="notice">${pill(notice.tone, notice.tone === "good" ? "Listo" : "Error")} ${esc(notice.text)}</div>` : ""}
    <div class="grid">
      ${card("Modelo activo", summary, { span: 1 })}
      ${card("Modelos locales (Ollama)", table([{ label: "Modelo" }, { label: "Tamaño", num: true }, { label: "" }], localRows), { span: 2 })}
      ${card("Modelos de APIs", table([{ label: "Modelo" }, { label: "Proveedor" }, { label: "" }], remoteRows, "Añade un proveedor y sus modelos para verlos aquí"), { span: 2 })}
      ${card(e ? `Editar ${e.name}` : "Añadir proveedor", form, { span: 1 })}
      ${card("Proveedores", table([{ label: "Proveedor" }, { label: "URL" }, { label: "Clave" }, { label: "Estado" }, { label: "" }], providerRows, "Sin proveedores configurados"), { span: 3 })}
    </div>`;
}

function bind(root: HTMLElement, providers: Provider[]): void {
  const say = (tone: "good" | "critical", text: string): void => { notice = { tone, text }; rerender(root); };

  root.querySelectorAll<HTMLButtonElement>("[data-use]").forEach((b) =>
    b.addEventListener("click", async () => {
      b.disabled = true; b.textContent = "Aplicando…";
      try { const r = await api.setModel(b.dataset.use || null); say(r.ok ? "good" : "critical", r.detail); }
      catch (err) { say("critical", String(err instanceof Error ? err.message : err)); }
    }));

  root.querySelectorAll<HTMLButtonElement>("[data-edit]").forEach((b) =>
    b.addEventListener("click", () => { editing = providers.find((p) => p.id === b.dataset.edit) ?? null; notice = null; rerender(root); }));

  root.querySelector("[data-cancel]")?.addEventListener("click", () => { editing = null; notice = null; rerender(root); });

  root.querySelectorAll<HTMLButtonElement>("[data-delete]").forEach((b) =>
    b.addEventListener("click", async () => {
      const id = b.dataset.delete!;
      if (!confirm(`¿Eliminar el proveedor ${id} y su clave?`)) return;
      try { const r = await api.deleteProvider(id); if (editing?.id === id) editing = null; say("good", r.detail); }
      catch (err) { say("critical", String(err instanceof Error ? err.message : err)); }
    }));

  root.querySelectorAll<HTMLButtonElement>("[data-discover]").forEach((b) =>
    b.addEventListener("click", async () => {
      const id = b.dataset.discover!;
      b.disabled = true; b.textContent = "Consultando…";
      try {
        const r = await api.discoverModels(id);
        const p = providers.find((x) => x.id === id)!;
        editing = { ...p, models: r.models.length > 40 ? [...p.models] : r.models };
        say("good", r.models.length > 40
          ? `${r.models.length} modelos disponibles; son muchos, añade a mano los que quieras: ${r.models.slice(0, 40).join(", ")}…`
          : `${r.detail}. Revisa la lista y guarda.`);
      } catch (err) { say("critical", String(err instanceof Error ? err.message : err)); }
    }));

  const form = root.querySelector<HTMLFormElement>("#provider-form");
  const preset = root.querySelector<HTMLSelectElement>("#pf-preset");
  preset?.addEventListener("change", () => {
    const p = PRESETS.find((x) => x.id === preset.value);
    if (!p || !form) return;
    const set = (n: string, v: string): void => { const el = form.elements.namedItem(n) as HTMLInputElement | null; if (el && !el.readOnly) el.value = v; };
    set("id", p.id); set("name", p.name); set("baseURL", p.baseURL); set("models", p.models.join("\n"));
  });
  form?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const f = new FormData(form);
    const str = (k: string): string => String(f.get(k) ?? "").trim();
    const input: ProviderInput = {
      id: str("id").toLowerCase(),
      name: str("name"),
      baseURL: str("baseURL"),
      models: str("models").split(/[\n,]/).map((s) => s.trim()).filter(Boolean),
      enabled: f.get("enabled") === "on",
    };
    if (str("apiKey")) input.apiKey = str("apiKey");
    if (str("apiKeyEnv")) input.apiKeyEnv = str("apiKeyEnv");
    try { const r = await api.saveProvider(input); editing = null; say("good", r.detail); }
    catch (err) { say("critical", String(err instanceof Error ? err.message : err)); }
  });
}
