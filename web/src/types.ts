// Shapes returned by the LocalLLM gateway (see Sources/LocalLLM/AppCoordinator.swift).

export type Num = number | null;

export interface Aggregate {
  requests: number;
  ok: Num;
  rejected: Num;
  errors: Num;
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  avg_tokens_per_sec: Num;
  max_tokens_per_sec: Num;
  avg_ttft_ms: Num;
  avg_queue_ms: Num;
  avg_total_ms: Num;
}

export interface Totals extends Aggregate {
  ttft_ms_p50: Num;
  ttft_ms_p95: Num;
  tokens_per_sec_p50: Num;
  tokens_per_sec_p95: Num;
}

export interface RecentRequest {
  time: string;
  client_app: string;
  endpoint: string;
  model: string;
  stream: number;
  priority: string;
  status: number;
  prompt_tokens: Num;
  completion_tokens: Num;
  ttft_ms: Num;
  tokens_per_sec: Num;
  prompt_eval_ms: Num;
  eval_ms: Num;
  queue_ms: Num;
  total_ms: Num;
  timing_source: string | null;
  error: string | null;
}

export interface Incident {
  time: string;
  kind: string;
  detail: string;
}

export interface MemorySnapshot {
  timestamp: string;
  totalBytes: number;
  availableBytes: number;
  freeBytes: number;
  activeBytes: number;
  inactiveBytes: number;
  wiredBytes: number;
  compressedBytes: number;
  purgeableBytes: number;
  fileBackedBytes: number;
  swapUsedBytes: number;
  swapoutsTotal: number;
  pressure: string;
  breakerOpen: boolean;
  thresholdBytes: number;
}

export interface LoadedModel {
  name: string;
  sizeBytes: number;
  sizeVRAMBytes: number;
  weightsBytes: number;
  kvCacheBytes: number;
  contextLength?: number;
  expiresAt?: string;
}

export interface Metrics {
  window: string;
  version: string;
  generatedAt: string;
  totals: Totals;
  byClient: (Aggregate & { client_app: string })[];
  byModel: (Aggregate & { model: string })[];
  byEndpoint: (Aggregate & { endpoint: string })[];
  recent: RecentRequest[];
  incidents: Incident[];
  live: {
    inFlight: number;
    queued: number;
    capacity: number;
    paused: boolean;
    breakerOpen: boolean;
    model: string;
    engine: string;
    memory: MemorySnapshot;
    loadedModels: LoadedModel[];
  };
}

export interface SeriesPoint {
  t: number;
  requests: number;
  failed: number;
  prompt_tokens: number;
  completion_tokens: number;
  tokens_per_sec: Num;
  ttft_ms: Num;
}

export interface Timeseries {
  window: string;
  bucketSeconds: number;
  from: number;
  to: number;
  points: SeriesPoint[];
}

export interface MemoryPoint {
  t: number;
  available: number;
  used: number;
  swap: number;
  breaker: boolean;
}

export interface MemoryEstimate {
  weightsBytes: number;
  kvCacheBytes: number;
  overheadBytes: number;
  totalBytes: number;
  budgetBytes: number;
  headroomBytes: number;
}

export interface MemoryInfo {
  now: MemorySnapshot;
  history: MemoryPoint[];
  loadedModels: LoadedModel[];
  weightsBytes: number;
  kvCacheBytes: number;
  plan: { model: string; budgetBytes: number; minFreeBytes: number; estimate: MemoryEstimate };
}

export interface HardwareInfo {
  chip: string;
  modelIdentifier: string;
  isAppleSilicon: boolean;
  performanceCores: number;
  efficiencyCores: number;
  logicalCores: number;
  gpuCores?: number;
  gpuName?: string;
  totalMemoryBytes: number;
  availableMemoryBytesAtLaunch: number;
  metalRecommendedWorkingSetBytes?: number;
  osVersion: string;
}

export interface ModelPlan {
  profileId: string;
  profileDescription: string;
  model: string;
  fallbackModels: string[];
  quantization: string;
  numCtx: number;
  numParallel: number;
  kvCacheType: string;
  flashAttention: boolean;
  numGPU: number;
  metalBudgetBytes: number;
  minFreeBytes: number;
  estimate: MemoryEstimate;
  reasons: string[];
  adjustments: string[];
}

export interface HardwareProfile {
  hardware: HardwareInfo;
  selection: ModelPlan;
  ollamaEnvironment: Record<string, string>;
  memoryNow: MemorySnapshot;
  loadedModels: LoadedModel[];
  configSource: string;
  summary: string;
}

export interface ModelsInfo {
  active: string;
  auto: string;
  override: string | null;
  installed: { name: string; sizeBytes: number }[];
  loaded: LoadedModel[];
  lastUsed: string | null;
  engine: string;
}

export interface SyncReport {
  trigger: string;
  outcome: string;
  detail: string;
  fromCommit?: string;
  toCommit?: string;
  changedFiles: string[];
  configReloaded: boolean;
  codeChanged: boolean;
  finishedAt: string;
}

export interface UpdaterStatus {
  state: string;
  remote: string;
  branch: string;
  repoPath: string;
  runningCommit: string;
  lastSyncAt?: string;
  headCommit?: string;
  headSubject?: string;
  headDate?: string;
  lastReport?: SyncReport;
  pendingCodeCommit?: string;
  badCommits: string[];
  nextSyncAt?: string;
}

export interface Health {
  status: string;
  pid: number;
  version: string;
  displayVersion: string;
  commit: string;
  uptimeSeconds: number;
  engine: string;
  model: string;
  breakerOpen: boolean;
}
