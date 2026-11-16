// Conversation history, kept in this browser's localStorage (the dashboard origin is the local gateway).

export interface ChatStats {
  model: string;
  /** Client-measured: request sent → first token (content or reasoning). */
  ttftMs: number | null;
  /** Engine-reported generation speed (eval_count / eval_duration). */
  tokensPerSec: number | null;
  promptTokens: number | null;
  outputTokens: number | null;
  /** Client-measured wall time of the whole request. */
  totalMs: number;
  queueMs: number | null;
  loadMs: number | null;
  promptEvalMs: number | null;
  promptTokensPerSec: number | null;
  evalMs: number | null;
  thinkingMs: number | null;
  doneReason: string | null;
}

export interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
  thinking?: string;
  stats?: ChatStats;
  error?: string;
  /** True only while the response is being streamed (never persisted as true). */
  pending?: boolean;
  createdAt: number;
}

export interface Conversation {
  id: string;
  title: string;
  /** null = the gateway's active model. */
  model: string | null;
  createdAt: number;
  updatedAt: number;
  messages: ChatMessage[];
}

export interface ChatPrefs {
  model: string | null;
  think: boolean;
  system: string;
}

const KEY = "localllm.chat.v1";
const PREFS_KEY = "localllm.chat.prefs.v1";

export function uid(): string {
  return (crypto.randomUUID?.() ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`).replace(/-/g, "").slice(0, 16);
}

export function loadConversations(): Conversation[] {
  try {
    const raw = localStorage.getItem(KEY);
    const list = raw ? (JSON.parse(raw) as Conversation[]) : [];
    if (!Array.isArray(list)) return [];
    // A reload mid-stream leaves a half answer: keep it, but mark it as interrupted.
    for (const c of list) {
      for (const m of c.messages) {
        if (m.pending) { m.pending = false; m.error ??= "Respuesta interrumpida"; }
      }
    }
    return list.sort((a, b) => b.updatedAt - a.updatedAt);
  } catch {
    return [];
  }
}

export function saveConversations(list: Conversation[]): void {
  try {
    // Drop empty drafts so "Nueva conversación" never clutters the history.
    localStorage.setItem(KEY, JSON.stringify(list.filter((c) => c.messages.length > 0)));
  } catch {
    /* storage full or blocked: the chat keeps working in memory */
  }
}

export function loadPrefs(): ChatPrefs {
  const fallback: ChatPrefs = { model: null, think: true, system: "" };
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    return raw ? { ...fallback, ...(JSON.parse(raw) as Partial<ChatPrefs>) } : fallback;
  } catch {
    return fallback;
  }
}

export function savePrefs(p: ChatPrefs): void {
  try { localStorage.setItem(PREFS_KEY, JSON.stringify(p)); } catch { /* ignore */ }
}

export function titleFrom(text: string): string {
  const one = text.replace(/\s+/g, " ").trim();
  return one.length > 52 ? `${one.slice(0, 50).trimEnd()}…` : one || "Nueva conversación";
}

/** Sidebar groups, newest first. */
export function groupLabel(ts: number, now = new Date()): string {
  const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const day = 86_400_000;
  if (ts >= startOfDay) return "Hoy";
  if (ts >= startOfDay - day) return "Ayer";
  if (ts >= startOfDay - 7 * day) return "Últimos 7 días";
  if (ts >= startOfDay - 30 * day) return "Últimos 30 días";
  return new Date(ts).toLocaleDateString("es-MX", { month: "long", year: "numeric" });
}
