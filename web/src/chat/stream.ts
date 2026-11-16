// Streaming client for the gateway's native /api/chat (NDJSON). The final chunk carries
// the engine's exact counters (prompt/eval tokens and durations), which feed the indicators.

import type { ChatStats } from "./store";

export interface WireMessage { role: "system" | "user" | "assistant"; content: string }

export type Phase = "connecting" | "prompt" | "thinking" | "writing";

export interface StreamCallbacks {
  onPhase(phase: Phase): void;
  onDelta(delta: { content?: string; thinking?: string }): void;
}

interface Chunk {
  model?: string;
  message?: { content?: string; thinking?: string };
  done?: boolean;
  done_reason?: string;
  error?: string;
  total_duration?: number;
  load_duration?: number;
  prompt_eval_count?: number;
  prompt_eval_duration?: number;
  eval_count?: number;
  eval_duration?: number;
}

export class ChatError extends Error {
  constructor(message: string, readonly status: number, readonly retryAfter: number | null = null) { super(message); }
}

const nsToMs = (ns: number | undefined): number | null => (ns && ns > 0 ? ns / 1e6 : null);

export async function streamChat(
  req: { model: string | null; messages: WireMessage[]; think: boolean | null },
  cb: StreamCallbacks,
  signal: AbortSignal,
): Promise<ChatStats> {
  const t0 = performance.now();
  cb.onPhase("connecting");
  const body: Record<string, unknown> = { messages: req.messages, stream: true };
  if (req.model) body.model = req.model;
  if (req.think !== null) body.think = req.think;

  const res = await fetch("/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Client-App": "localllm-chat", "X-Priority": "interactive" },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok || !res.body) {
    let msg = `HTTP ${res.status}`;
    try {
      const j = (await res.json()) as { error?: string | { message?: string } };
      msg = typeof j.error === "string" ? j.error : j.error?.message ?? msg;
    } catch { /* not JSON */ }
    const ra = Number(res.headers.get("Retry-After"));
    throw new ChatError(msg, res.status, Number.isFinite(ra) && ra > 0 ? ra : null);
  }

  const queueHeader = Number(res.headers.get("X-LocalLLM-Queue-Ms"));
  let model = res.headers.get("X-LocalLLM-Model") ?? req.model ?? "";
  cb.onPhase("prompt");

  let ttft: number | null = null;
  let firstContent: number | null = null;
  let last: Chunk | null = null;
  let phase: Phase = "prompt";
  const setPhase = (p: Phase): void => { if (p !== phase) { phase = p; cb.onPhase(p); } };

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const handle = (line: string): void => {
    if (!line.trim()) return;
    let chunk: Chunk;
    try { chunk = JSON.parse(line) as Chunk; } catch { return; }
    if (chunk.error) throw new ChatError(chunk.error, 500);
    if (chunk.model) model = chunk.model;
    const content = chunk.message?.content ?? "";
    const thinking = chunk.message?.thinking ?? "";
    if ((content || thinking) && ttft === null) ttft = performance.now() - t0;
    if (thinking) setPhase("thinking");
    if (content) { if (firstContent === null) firstContent = performance.now(); setPhase("writing"); }
    if (content || thinking) cb.onDelta({ content: content || undefined, thinking: thinking || undefined });
    if (chunk.done) last = chunk;
  };

  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      handle(buf.slice(0, nl));
      buf = buf.slice(nl + 1);
    }
  }
  handle(buf + decoder.decode());

  const end = performance.now();
  const f = last as Chunk | null;
  const evalMs = nsToMs(f?.eval_duration);
  const promptMs = nsToMs(f?.prompt_eval_duration);
  return {
    model,
    ttftMs: ttft,
    tokensPerSec: f?.eval_count && evalMs ? f.eval_count / (evalMs / 1000) : null,
    promptTokens: f?.prompt_eval_count ?? null,
    outputTokens: f?.eval_count ?? null,
    totalMs: end - t0,
    queueMs: Number.isFinite(queueHeader) ? queueHeader : null,
    loadMs: nsToMs(f?.load_duration),
    promptEvalMs: promptMs,
    promptTokensPerSec: f?.prompt_eval_count && promptMs ? f.prompt_eval_count / (promptMs / 1000) : null,
    evalMs,
    thinkingMs: ttft !== null && firstContent !== null && firstContent - t0 > ttft + 1 ? firstContent - t0 - ttft : null,
    doneReason: f?.done_reason ?? null,
  };
}
