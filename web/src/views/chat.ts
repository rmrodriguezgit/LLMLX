import { api } from "../api";
import { renderMarkdown } from "../chat/markdown";
import {
  type ChatMessage, type ChatPrefs, type ChatStats, type Conversation,
  groupLabel, loadConversations, loadPrefs, saveConversations, savePrefs, titleFrom, uid,
} from "../chat/store";
import { ChatError, type Phase, type WireMessage, streamChat } from "../chat/stream";
import { compact, esc, fixed, int, ms } from "../format";
import { pill } from "../ui";
import type { View } from "./view";

const ICON = {
  plus: '<path d="M12 5v14M5 12h14"/>',
  send: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="1.5"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
  pencil: '<path d="M4 20h4L19 9l-4-4L4 16v4z"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>',
  retry: '<path d="M20 12a8 8 0 1 1-2.3-5.7L20 8"/><path d="M20 3v5h-5"/>',
  list: '<path d="M4 6h16M4 12h16M4 18h16"/>',
  bolt: '<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>',
};
const svg = (p: string): string => `<svg viewBox="0 0 24 24" aria-hidden="true">${p}</svg>`;

const SUGGESTIONS = [
  "Explícame qué es la KV-cache y por qué consume RAM",
  "Escribe una función en TypeScript que agrupe un arreglo por clave",
  "Resume en 5 puntos las ventajas de correr un LLM en local",
  "Dame un plan de estudio de 4 semanas para aprender Swift",
];

const PHASE_LABEL: Record<Phase, string> = {
  connecting: "Conectando con el gateway…",
  prompt: "Procesando el prompt…",
  thinking: "Razonando…",
  writing: "Escribiendo…",
};

interface Live {
  convId: string;
  msgId: string;
  phase: Phase;
  started: number;
  firstToken: number | null;
  chunks: number;
  abort: AbortController;
}

const state = {
  conversations: loadConversations(),
  prefs: loadPrefs() as ChatPrefs,
  currentId: null as string | null,
  draft: null as Conversation | null,
  filter: "",
  models: [] as string[],
  activeModel: "",
  live: null as Live | null,
  listOpen: false,
  /** Models that rejected `think`: never send it to them again this session. */
  noThink: new Set<string>(),
};

let root: HTMLElement | null = null;
let tick: number | undefined;
let paintQueued = false;
let stickToBottom = true;

// ---------- state helpers ----------

function current(): Conversation {
  const found = state.conversations.find((c) => c.id === state.currentId);
  if (found) return found;
  if (!state.draft) {
    state.draft = { id: uid(), title: "Nueva conversación", model: state.prefs.model, createdAt: Date.now(), updatedAt: Date.now(), messages: [] };
  }
  state.currentId = state.draft.id;
  return state.draft;
}

function persist(): void { saveConversations(state.conversations); }

function newConversation(): void {
  if (state.live) return;
  state.draft = null;
  state.currentId = null;
  current();
  state.listOpen = false;
  paintAll();
  focusComposer();
}

function selectConversation(id: string): void {
  if (state.currentId === id) { state.listOpen = false; paintAll(); return; }
  state.currentId = id;
  state.draft = null;
  state.listOpen = false;
  stickToBottom = true;
  paintAll();
  scrollToBottom();
}

function deleteConversation(id: string): void {
  const c = state.conversations.find((x) => x.id === id);
  if (!c || !confirm(`¿Eliminar «${c.title}»? No se puede deshacer.`)) return;
  if (state.live?.convId === id) state.live.abort.abort();
  state.conversations = state.conversations.filter((x) => x.id !== id);
  persist();
  if (state.currentId === id) { state.currentId = null; state.draft = null; }
  paintAll();
}

// ---------- sending ----------

/** Splits `<think>…</think>` that some models inline in content when reasoning isn't separated. */
function splitThink(m: ChatMessage): { content: string; thinking: string } {
  let content = m.content;
  let thinking = m.thinking ?? "";
  const open = content.indexOf("<think>");
  if (open === 0 || (open > 0 && !content.slice(0, open).trim())) {
    const close = content.indexOf("</think>");
    if (close < 0) return { content: "", thinking: thinking + content.slice(open + 7) };
    thinking += content.slice(open + 7, close);
    content = content.slice(close + 8).replace(/^\s+/, "");
  }
  return { content, thinking: thinking.trim() };
}

function wireHistory(conv: Conversation, upTo: number): WireMessage[] {
  const msgs: WireMessage[] = [];
  if (state.prefs.system.trim()) msgs.push({ role: "system", content: state.prefs.system.trim() });
  for (const m of conv.messages.slice(0, upTo)) {
    if (m.role === "assistant" && (m.error && !m.content)) continue;
    msgs.push({ role: m.role, content: m.role === "assistant" ? splitThink(m).content : m.content });
  }
  // Drop a dangling failed exchange so the model never sees two user turns in a row.
  return msgs.filter((m, i) => !(m.role === "user" && msgs[i + 1]?.role === "user"));
}

async function send(text: string): Promise<void> {
  const prompt = text.trim();
  if (!prompt || state.live) return;
  const conv = current();
  if (state.draft === conv) {
    conv.title = titleFrom(prompt);
    state.conversations.unshift(conv);
    state.draft = null;
  }
  conv.messages.push({ id: uid(), role: "user", content: prompt, createdAt: Date.now() });
  await respond(conv);
}

async function respond(conv: Conversation): Promise<void> {
  const reply: ChatMessage = { id: uid(), role: "assistant", content: "", pending: true, createdAt: Date.now() };
  conv.messages.push(reply);
  conv.updatedAt = Date.now();
  conv.model = state.prefs.model;
  persist();

  const live: Live = { convId: conv.id, msgId: reply.id, phase: "connecting", started: performance.now(), firstToken: null, chunks: 0, abort: new AbortController() };
  state.live = live;
  stickToBottom = true;
  paintAll();
  scrollToBottom();
  tick = window.setInterval(paintLive, 200);

  const model = state.prefs.model;
  const key = model ?? state.activeModel;
  let think: boolean | null = state.noThink.has(key) ? null : state.prefs.think;
  const history = wireHistory(conv, conv.messages.length - 1);

  const run = (): Promise<ChatStats> =>
    streamChat({ model, messages: history, think }, {
      onPhase: (p) => { live.phase = p; paintLive(); },
      onDelta: (d) => {
        if (live.firstToken === null) live.firstToken = performance.now();
        live.chunks++;
        if (d.content) reply.content += d.content;
        if (d.thinking) reply.thinking = (reply.thinking ?? "") + d.thinking;
        queuePaint();
      },
    }, live.abort.signal);

  try {
    try {
      reply.stats = await run();
    } catch (err) {
      // Non-reasoning models reject `think`; retry once without it and remember.
      if (err instanceof ChatError && think !== null && /think/i.test(err.message) && !reply.content) {
        state.noThink.add(key);
        think = null;
        reply.stats = await run();
      } else throw err;
    }
  } catch (err) {
    if (live.abort.signal.aborted) {
      reply.error = "Detenida por ti";
      reply.stats = {
        model: model ?? state.activeModel, ttftMs: live.firstToken ? live.firstToken - live.started : null, tokensPerSec: null,
        promptTokens: null, outputTokens: live.chunks, totalMs: performance.now() - live.started, queueMs: null, loadMs: null,
        promptEvalMs: null, promptTokensPerSec: null, evalMs: null, thinkingMs: null, doneReason: "stop",
      };
    } else if (err instanceof ChatError && err.status === 429) {
      reply.error = `${err.message}${err.retryAfter ? ` (reintenta en ${err.retryAfter} s)` : ""}`;
    } else {
      reply.error = err instanceof Error ? err.message : String(err);
    }
  } finally {
    window.clearInterval(tick);
    reply.pending = false;
    state.live = null;
    conv.updatedAt = Date.now();
    persist();
    paintAll();
    if (stickToBottom) scrollToBottom();
    focusComposer();
  }
}

function regenerate(msgId: string): void {
  const conv = current();
  const idx = conv.messages.findIndex((m) => m.id === msgId);
  if (idx < 0 || state.live) return;
  conv.messages.splice(idx);
  void respond(conv);
}

function editAndResend(msgId: string): void {
  const conv = current();
  const idx = conv.messages.findIndex((m) => m.id === msgId);
  if (idx < 0 || state.live) return;
  const text = conv.messages[idx]!.content;
  conv.messages.splice(idx);
  persist();
  paintAll();
  const ta = root?.querySelector<HTMLTextAreaElement>("#chat-input");
  if (ta) { ta.value = text; autosize(ta); ta.focus(); }
}

// ---------- rendering ----------

function statsChips(s: ChatStats): string {
  const chip = (label: string, value: string, title: string, cls = ""): string =>
    `<span class="chip ${cls}" title="${esc(title)}"><span>${esc(label)}</span><b>${esc(value)}</b></span>`;
  const parts = [
    s.tokensPerSec != null ? chip("", `${fixed(s.tokensPerSec, 1)} tok/s`, "Velocidad de generación reportada por el motor", "chip-accent") : "",
    s.ttftMs != null ? chip("TTFT", ms(s.ttftMs), "Tiempo hasta el primer token (medido en el navegador)") : "",
    s.outputTokens != null ? chip("Salida", `${int(s.outputTokens)} tok`, "Tokens generados") : "",
    s.promptTokens != null ? chip("Entrada", `${compact(s.promptTokens)} tok`, "Tokens del prompt evaluados (historial incluido)") : "",
    chip("Total", ms(s.totalMs), "Duración completa de la petición"),
  ];
  return parts.join("");
}

function statsDetails(s: ChatStats): string {
  const rows: [string, string][] = [
    ["Modelo", s.model || "—"],
    ["Tiempo hasta el primer token", ms(s.ttftMs)],
    ["Espera en cola del gateway", ms(s.queueMs)],
    ["Carga del modelo", ms(s.loadMs)],
    ["Evaluación del prompt", `${ms(s.promptEvalMs)}${s.promptTokensPerSec ? ` · ${fixed(s.promptTokensPerSec, 0)} tok/s` : ""}`],
    ["Razonamiento", ms(s.thinkingMs)],
    ["Generación", `${ms(s.evalMs)}${s.tokensPerSec ? ` · ${fixed(s.tokensPerSec, 1)} tok/s` : ""}`],
    ["Tokens de entrada / salida", `${int(s.promptTokens)} / ${int(s.outputTokens)}`],
    ["Duración total", ms(s.totalMs)],
    ["Motivo de fin", s.doneReason === "length" ? "Límite de longitud" : s.doneReason === "stop" ? "Completa" : s.doneReason ?? "—"],
  ];
  return `<dl class="chat-defs">${rows.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join("")}</dl>`;
}

function messageHTML(m: ChatMessage, isLast: boolean): string {
  if (m.role === "user") {
    return `<div class="msg msg-user" data-mid="${m.id}">
      <div class="bubble">${esc(m.content).replace(/\n/g, "<br>")}</div>
      <div class="msg-actions">
        <button type="button" class="icon-btn" data-act="copy" title="Copiar">${svg(ICON.copy)}</button>
        <button type="button" class="icon-btn" data-act="edit" title="Editar y reenviar">${svg(ICON.pencil)}</button>
      </div>
    </div>`;
  }
  return `<div class="msg msg-assistant" data-mid="${m.id}">${assistantInner(m, isLast)}</div>`;
}

function assistantInner(m: ChatMessage, isLast: boolean): string {
  const { content, thinking } = splitThink(m);
  const live = m.pending && state.live?.msgId === m.id ? state.live : null;
  const thinkingOpen = live && !content;
  const think = thinking
    ? `<details class="thinking" ${thinkingOpen ? "open" : ""}><summary>${live && !content ? "Razonando…" : "Razonamiento"}
        ${m.stats?.thinkingMs ? `<span class="muted">· ${esc(ms(m.stats.thinkingMs))}</span>` : ""}</summary>
        <div class="thinking-body">${esc(thinking).replace(/\n/g, "<br>")}</div></details>`
    : "";
  const body = content ? `<div class="md">${renderMarkdown(content)}${live ? '<span class="caret"></span>' : ""}</div>` : "";
  const waiting = live && !content && !thinking ? `<div class="typing"><i></i><i></i><i></i></div>` : "";
  const error = m.error ? `<div class="msg-error">${pill(m.error === "Detenida por ti" ? "neutral" : "critical", m.error)}</div>` : "";
  const foot = live
    ? `<div class="live-indicator" id="live-ind">${liveText(live)}</div>`
    : `<div class="msg-foot">
        ${m.stats ? `<div class="chips">${statsChips(m.stats)}</div>` : ""}
        <div class="msg-actions">
          ${content ? `<button type="button" class="icon-btn" data-act="copy" title="Copiar respuesta">${svg(ICON.copy)}</button>` : ""}
          ${isLast ? `<button type="button" class="icon-btn" data-act="retry" title="Regenerar">${svg(ICON.retry)}</button>` : ""}
          ${m.stats ? `<button type="button" class="icon-btn text-btn" data-act="details" title="Ver indicadores">Detalles</button>` : ""}
        </div>
      </div>
      ${m.stats ? `<div class="msg-details" hidden>${statsDetails(m.stats)}</div>` : ""}`;
  return `${think}${waiting}${body}${error}${foot}`;
}

function liveText(l: Live): string {
  const now = performance.now();
  const elapsed = (now - l.started) / 1000;
  const genSecs = l.firstToken ? (now - l.firstToken) / 1000 : 0;
  const rate = genSecs > 0.4 ? l.chunks / genSecs : null;
  return `<span class="pulse"></span><b>${esc(PHASE_LABEL[l.phase])}</b>
    <span>${elapsed.toFixed(1)} s</span>
    ${l.firstToken ? `<span>TTFT ${esc(ms(l.firstToken - l.started))}</span>` : ""}
    ${l.chunks ? `<span>${int(l.chunks)} tok</span>` : ""}
    ${rate ? `<span>≈ ${fixed(rate, 1)} tok/s</span>` : ""}`;
}

function listHTML(): string {
  const q = state.filter.trim().toLowerCase();
  const items = state.conversations.filter((c) => !q || c.title.toLowerCase().includes(q)
    || c.messages.some((m) => m.content.toLowerCase().includes(q)));
  if (!items.length) {
    return `<div class="chat-list-empty">${q ? "Sin coincidencias" : "Aún no hay conversaciones. Escribe tu primera pregunta."}</div>`;
  }
  let lastGroup = "";
  const now = new Date();
  return items.map((c) => {
    const g = groupLabel(c.updatedAt, now);
    const head = g !== lastGroup ? `<div class="chat-group">${esc(g)}</div>` : "";
    lastGroup = g;
    const busy = state.live?.convId === c.id;
    return `${head}<div class="conv ${c.id === state.currentId ? "active" : ""}" data-cid="${c.id}" role="button" tabindex="0">
      ${busy ? '<span class="pulse" title="Generando"></span>' : ""}
      <span class="conv-title">${esc(c.title)}</span>
      <span class="conv-actions">
        <button type="button" class="icon-btn" data-act="rename" title="Renombrar">${svg(ICON.pencil)}</button>
        <button type="button" class="icon-btn" data-act="delete" title="Eliminar">${svg(ICON.trash)}</button>
      </span>
    </div>`;
  }).join("");
}

function emptyHTML(): string {
  return `<div class="chat-empty">
    <img src="logo.png" alt="" width="56" height="56">
    <h2>¿En qué te ayudo?</h2>
    <p class="muted">Todo se ejecuta en tu Mac con <span class="mono">${esc(state.prefs.model ?? state.activeModel ?? "el modelo activo")}</span>. Nada sale de tu equipo.</p>
    <div class="suggestions">${SUGGESTIONS.map((s) => `<button type="button" class="suggestion" data-suggest="${esc(s)}">${esc(s)}</button>`).join("")}</div>
  </div>`;
}

function messagesHTML(conv: Conversation): string {
  if (!conv.messages.length) return emptyHTML();
  const lastAssistant = [...conv.messages].reverse().find((m) => m.role === "assistant")?.id;
  return conv.messages.map((m) => messageHTML(m, m.id === lastAssistant)).join("");
}

function convSummary(conv: Conversation): string {
  const done = conv.messages.filter((m) => m.stats);
  if (!done.length) return "";
  const out = done.reduce((a, m) => a + (m.stats!.outputTokens ?? 0), 0);
  const lastPrompt = done[done.length - 1]!.stats!;
  const ctx = (lastPrompt.promptTokens ?? 0) + (lastPrompt.outputTokens ?? 0);
  const rates = done.map((m) => m.stats!.tokensPerSec).filter((x): x is number => x != null);
  const avg = rates.length ? rates.reduce((a, b) => a + b, 0) / rates.length : null;
  return `<span title="Tokens que ocupa la conversación en el contexto del modelo">Contexto ${compact(ctx)} tok</span>
    <span title="Tokens generados en toda la conversación">Generados ${compact(out)}</span>
    ${avg ? `<span title="Velocidad media de las respuestas">${fixed(avg, 1)} tok/s medio</span>` : ""}`;
}

function modelOptions(): string {
  const sel = state.prefs.model;
  const opts = [`<option value="" ${sel === null ? "selected" : ""}>Automático · ${esc(state.activeModel || "modelo activo")}</option>`];
  const names = new Set(state.models);
  if (sel && !names.has(sel)) names.add(sel);
  for (const n of names) opts.push(`<option value="${esc(n)}" ${n === sel ? "selected" : ""}>${esc(n)}</option>`);
  return opts.join("");
}

function shellHTML(): string {
  return `<div class="chat ${state.listOpen ? "list-open" : ""}">
    <aside class="chat-list">
      <button type="button" class="new-chat" data-act="new">${svg(ICON.plus)}Nueva conversación</button>
      <input type="search" class="chat-search" id="chat-search" placeholder="Buscar conversaciones" value="${esc(state.filter)}" aria-label="Buscar conversaciones">
      <div class="chat-list-items" id="chat-list-items"></div>
    </aside>
    <div class="chat-backdrop" data-act="close-list"></div>
    <section class="chat-main">
      <header class="chat-head">
        <button type="button" class="icon-btn list-toggle" data-act="toggle-list" title="Conversaciones">${svg(ICON.list)}</button>
        <div class="chat-head-title"><h2 id="chat-title"></h2><div class="chat-summary" id="chat-summary"></div></div>
        <div class="chat-head-controls">
          <label class="think-toggle" title="Pide al modelo que razone antes de responder (si lo soporta)">
            <input type="checkbox" id="chat-think" ${state.prefs.think ? "checked" : ""}> Razonar
          </label>
          <select id="chat-model" class="chat-model" aria-label="Modelo">${modelOptions()}</select>
          <button type="button" class="icon-btn text-btn" data-act="system" title="Instrucciones del sistema">Instrucciones</button>
        </div>
      </header>
      <div class="system-box" id="system-box" hidden>
        <label for="chat-system">Instrucciones del sistema (se envían al inicio de cada conversación)</label>
        <textarea id="chat-system" rows="3" placeholder="Ej.: Responde siempre en español y de forma concisa.">${esc(state.prefs.system)}</textarea>
      </div>
      <div class="chat-scroll" id="chat-scroll"><div class="chat-messages" id="chat-messages"></div></div>
      <form class="composer" id="composer">
        <textarea id="chat-input" rows="1" placeholder="Escribe un mensaje…" aria-label="Mensaje"></textarea>
        <button type="submit" class="send-btn" id="send-btn" title="Enviar">${svg(ICON.send)}</button>
      </form>
      <p class="composer-note muted">Enter envía · Shift+Enter nueva línea · Las conversaciones se guardan solo en este navegador.</p>
    </section>
  </div>`;
}

function paintAll(): void {
  if (!root) return;
  const conv = current();
  root.querySelector(".chat")?.classList.toggle("list-open", state.listOpen);
  root.querySelector("#chat-list-items")!.innerHTML = listHTML();
  root.querySelector("#chat-title")!.textContent = conv.messages.length ? conv.title : "Nueva conversación";
  root.querySelector("#chat-summary")!.innerHTML = convSummary(conv);
  root.querySelector("#chat-messages")!.innerHTML = messagesHTML(conv);
  const sel = root.querySelector<HTMLSelectElement>("#chat-model")!;
  sel.innerHTML = modelOptions();
  const btn = root.querySelector<HTMLButtonElement>("#send-btn")!;
  const busy = !!state.live;
  btn.innerHTML = svg(busy ? ICON.stop : ICON.send);
  btn.title = busy ? "Detener" : "Enviar";
  btn.classList.toggle("stop", busy);
  root.querySelector<HTMLButtonElement>(".new-chat")!.disabled = busy;
}

function queuePaint(): void {
  if (paintQueued) return;
  paintQueued = true;
  requestAnimationFrame(() => {
    paintQueued = false;
    const l = state.live;
    if (!root || !l || l.convId !== state.currentId) return;
    const conv = current();
    const m = conv.messages.find((x) => x.id === l.msgId);
    const el = root.querySelector<HTMLElement>(`[data-mid="${l.msgId}"]`);
    if (!m || !el) return;
    const openThinking = el.querySelector("details.thinking")?.hasAttribute("open");
    el.innerHTML = assistantInner(m, true);
    // Respect the user's choice to open/close the reasoning panel while streaming.
    const det = el.querySelector("details.thinking");
    if (det && openThinking !== undefined) det.toggleAttribute("open", openThinking);
    if (stickToBottom) scrollToBottom();
  });
}

function paintLive(): void {
  const l = state.live;
  const el = root?.querySelector("#live-ind");
  if (l && el) el.innerHTML = liveText(l);
  if (l && root && !el && l.convId === state.currentId) queuePaint();
}

function scrollToBottom(): void {
  const s = root?.querySelector<HTMLElement>("#chat-scroll");
  if (s) s.scrollTop = s.scrollHeight;
}

function focusComposer(): void {
  if (matchMedia("(pointer: fine)").matches) root?.querySelector<HTMLTextAreaElement>("#chat-input")?.focus();
}

function autosize(ta: HTMLTextAreaElement): void {
  ta.style.height = "auto";
  // Empty: let rows=1 decide, otherwise WebKit sizes to the wrapped placeholder.
  if (ta.value) ta.style.height = `${Math.min(ta.scrollHeight, 220)}px`;
}

async function copy(text: string, btn: HTMLElement): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    btn.classList.add("copied");
    window.setTimeout(() => btn.classList.remove("copied"), 1200);
  } catch { /* clipboard blocked */ }
}

function startRename(item: HTMLElement, id: string): void {
  const conv = state.conversations.find((c) => c.id === id);
  if (!conv) return;
  const titleEl = item.querySelector(".conv-title")!;
  const input = document.createElement("input");
  input.className = "conv-rename";
  input.value = conv.title;
  titleEl.replaceWith(input);
  input.focus();
  input.select();
  let done = false;
  const finish = (save: boolean): void => {
    if (done) return;
    done = true;
    if (save && input.value.trim()) { conv.title = input.value.trim().slice(0, 80); persist(); }
    paintAll();
  };
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); finish(true); }
    if (e.key === "Escape") finish(false);
    e.stopPropagation();
  });
  input.addEventListener("blur", () => finish(true));
  input.addEventListener("click", (e) => e.stopPropagation());
}

// ---------- wiring ----------

function wire(el: HTMLElement): void {
  const ta = el.querySelector<HTMLTextAreaElement>("#chat-input")!;
  const scroller = el.querySelector<HTMLElement>("#chat-scroll")!;

  el.querySelector<HTMLFormElement>("#composer")!.addEventListener("submit", (e) => {
    e.preventDefault();
    if (state.live) { state.live.abort.abort(); return; }
    const text = ta.value;
    if (!text.trim()) return;
    ta.value = "";
    autosize(ta);
    void send(text);
  });
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      if (!state.live) el.querySelector<HTMLFormElement>("#composer")!.requestSubmit();
    }
  });
  ta.addEventListener("input", () => autosize(ta));

  scroller.addEventListener("scroll", () => {
    stickToBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 60;
  }, { passive: true });

  el.querySelector<HTMLInputElement>("#chat-search")!.addEventListener("input", (e) => {
    state.filter = (e.target as HTMLInputElement).value;
    el.querySelector("#chat-list-items")!.innerHTML = listHTML();
  });
  el.querySelector<HTMLSelectElement>("#chat-model")!.addEventListener("change", (e) => {
    const v = (e.target as HTMLSelectElement).value;
    state.prefs.model = v || null;
    savePrefs(state.prefs);
    const conv = current();
    if (!conv.messages.length) root!.querySelector("#chat-messages")!.innerHTML = emptyHTML();
  });
  el.querySelector<HTMLInputElement>("#chat-think")!.addEventListener("change", (e) => {
    state.prefs.think = (e.target as HTMLInputElement).checked;
    savePrefs(state.prefs);
  });
  el.querySelector<HTMLTextAreaElement>("#chat-system")!.addEventListener("input", (e) => {
    state.prefs.system = (e.target as HTMLTextAreaElement).value;
    savePrefs(state.prefs);
  });

  el.addEventListener("keydown", (e) => {
    const conv = (e.target as HTMLElement).closest<HTMLElement>(".conv");
    if (conv && (e.key === "Enter" || e.key === " ") && e.target === conv) { e.preventDefault(); selectConversation(conv.dataset.cid!); }
  });

  el.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    const act = t.closest<HTMLElement>("[data-act]")?.dataset.act;
    const convEl = t.closest<HTMLElement>(".conv");
    const msgEl = t.closest<HTMLElement>("[data-mid]");

    const sug = t.closest<HTMLElement>("[data-suggest]");
    if (sug) { void send(sug.dataset.suggest!); return; }

    const codeBtn = t.closest<HTMLElement>("[data-copy-code]");
    if (codeBtn) {
      const code = codeBtn.closest(".md-code")?.querySelector("code")?.textContent ?? "";
      void copy(code, codeBtn);
      return;
    }

    if (convEl && act === "delete") { e.stopPropagation(); deleteConversation(convEl.dataset.cid!); return; }
    if (convEl && act === "rename") { e.stopPropagation(); startRename(convEl, convEl.dataset.cid!); return; }
    if (convEl && !act) { selectConversation(convEl.dataset.cid!); return; }

    switch (act) {
      case "new": newConversation(); return;
      case "toggle-list": state.listOpen = !state.listOpen; root?.querySelector(".chat")?.classList.toggle("list-open", state.listOpen); return;
      case "close-list": state.listOpen = false; root?.querySelector(".chat")?.classList.remove("list-open"); return;
      case "system": {
        const box = root!.querySelector<HTMLElement>("#system-box")!;
        box.hidden = !box.hidden;
        if (!box.hidden) root!.querySelector<HTMLTextAreaElement>("#chat-system")!.focus();
        return;
      }
    }
    if (!msgEl || !act) return;
    const m = current().messages.find((x) => x.id === msgEl.dataset.mid);
    if (!m) return;
    const btn = t.closest<HTMLElement>("[data-act]")!;
    if (act === "copy") void copy(m.role === "assistant" ? splitThink(m).content : m.content, btn);
    if (act === "retry") regenerate(m.id);
    if (act === "edit") editAndResend(m.id);
    if (act === "details") {
      const d = msgEl.querySelector<HTMLElement>(".msg-details");
      if (d) { d.hidden = !d.hidden; btn.classList.toggle("on", !d.hidden); }
    }
  });
}

async function loadModels(): Promise<void> {
  try {
    const info = await api.models();
    state.models = [...info.installed.map((m) => m.name), ...(info.remote ?? []).flatMap((g) => g.models)];
    state.activeModel = info.active;
    if (state.prefs.model && !state.models.includes(state.prefs.model)) { state.prefs.model = null; savePrefs(state.prefs); }
  } catch { /* gateway offline: the send will surface the error */ }
}

export const chatView: View = {
  title: "Chat",
  subtitle: "Conversa con el modelo activo (local o API)",
  refreshMs: 0,
  persistent: true,
  async render(el) {
    root = el;
    el.innerHTML = shellHTML();
    wire(el);
    paintAll();
    scrollToBottom();
    await loadModels();
    if (root === el) {
      el.querySelector<HTMLSelectElement>("#chat-model")!.innerHTML = modelOptions();
      if (!current().messages.length) el.querySelector("#chat-messages")!.innerHTML = emptyHTML();
      focusComposer();
    }
  },
};
