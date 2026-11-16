import type {
  Health, HardwareProfile, MemoryInfo, Metrics, ModelsInfo, SyncReport, Timeseries, UpdaterStatus,
} from "./types";

async function getJSON<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { "X-Client-App": "localllm-dashboard" }, cache: "no-store" });
  if (!res.ok) throw new Error(`${path} → HTTP ${res.status}`);
  return (await res.json()) as T;
}

async function postJSON<T>(path: string, body: unknown = {}): Promise<T> {
  const res = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Client-App": "localllm-dashboard" },
    body: JSON.stringify(body),
  });
  const data = (await res.json()) as T;
  if (!res.ok && res.status !== 202) throw new Error(`${path} → HTTP ${res.status}: ${JSON.stringify(data)}`);
  return data;
}

export const api = {
  health: () => getJSON<Health>("/health"),
  metrics: (window: string) => getJSON<Metrics>(`/v1/metrics?window=${encodeURIComponent(window)}`),
  timeseries: (window: string) => getJSON<Timeseries>(`/v1/metrics/timeseries?window=${encodeURIComponent(window)}`),
  memory: () => getJSON<MemoryInfo>("/v1/system/memory"),
  profile: () => getJSON<HardwareProfile>("/v1/hardware-profile"),
  models: () => getJSON<ModelsInfo>("/v1/system/models"),
  gitStatus: () => getJSON<UpdaterStatus>("/v1/system/git-status"),
  gitSync: () => postJSON<SyncReport>("/v1/system/git-sync"),
  setModel: (model: string | null) => postJSON<{ ok: boolean; detail: string }>("/v1/system/model", { model }),
};
