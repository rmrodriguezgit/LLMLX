// Generated from config/profiles.json — last-resort fallback when no profiles.json is found.
// Regenerate with: ./scripts/embed_config.sh
enum EmbeddedConfig {
    static let json = #"""
{
  "schemaVersion": 1,
  "gateway": {
    "host": "127.0.0.1",
    "port": 11500,
    "maxQueueDepth": 64,
    "queueTimeoutSeconds": 120,
    "drainTimeoutSeconds": 120,
    "maxRequestBodyMB": 64,
    "allowedOrigins": [
      "http://localhost",
      "http://127.0.0.1",
      "vscode-webview://",
      "app://",
      "file://"
    ]
  },
  "ollama": {
    "port": 11501,
    "keepAlive": "30m",
    "maxLoadedModels": 1,
    "maxQueue": 256,
    "modelsDir": null,
    "autoPull": true,
    "warmup": true,
    "extraEnv": {}
  },
  "memoryGuard": {
    "pollIntervalMs": 500,
    "hysteresisGB": 0.7,
    "recoverySeconds": 5,
    "retryAfterSeconds": 5,
    "purgeIdleModelOnPressure": true,
    "normalPressureFloorFraction": 0.5
  },
  "routing": {
    "aliases": {
      "default": "$auto",
      "local": "$auto",
      "gpt-4o": "$auto",
      "gpt-4o-mini": "$auto",
      "gpt-4.1": "$auto",
      "gpt-3.5-turbo": "$auto"
    },
    "passthroughInstalledModels": true,
    "clientPriorities": {
      "Xcode": "high",
      "Cursor": "high",
      "Code": "high",
      "batch-worker": "low",
      "Quantlabs-Cerebro": "high",
      "Quantlabs-Cerebro-Blueprint": "normal"
    }
  },
  "updater": {
    "enabled": true,
    "remote": "https://github.com/rmrodriguezgit/LLMLX.git",
    "branch": "main",
    "intervalMinutes": 15,
    "autoRebuild": true,
    "healthCheckTimeoutSeconds": 10,
    "buildTimeoutMinutes": 25
  },
  "profiles": [
    {
      "id": "apple-8gb",
      "description": "Apple Silicon base 8 GB (M1/M2/M3)",
      "minMemoryGB": 0,
      "maxMemoryGB": 12,
      "model": "qwen3:4b",
      "fallbackModels": ["llama3.2:3b"],
      "quantization": "Q4_K_M",
      "numCtx": 4096,
      "maxCtx": 4096,
      "minCtx": 2048,
      "numParallel": 1,
      "kvCacheType": "q8_0",
      "flashAttention": true,
      "numGPU": 999,
      "metalBudgetGB": 5.3,
      "minFreeGB": 1.0,
      "estimatedWeightsGB": 2.6,
      "kvBytesPerTokenF16": 147456,
      "computeOverheadGB": 0.4
    },
    {
      "id": "apple-16gb",
      "description": "Apple M3 / M2 / M1 16 GB unified memory (primary target)",
      "minMemoryGB": 12,
      "maxMemoryGB": 20,
      "model": "qwen3:8b",
      "fallbackModels": ["qwen2.5:7b"],
      "quantization": "Q4_K_M",
      "numCtx": 8192,
      "maxCtx": 16384,
      "minCtx": 4096,
      "numParallel": 2,
      "kvCacheType": "q8_0",
      "flashAttention": true,
      "numGPU": 999,
      "metalBudgetGB": 10.75,
      "minFreeGB": 1.8,
      "estimatedWeightsGB": 5.2,
      "kvBytesPerTokenF16": 147456,
      "computeOverheadGB": 0.6
    },
    {
      "id": "apple-24-48gb",
      "description": "Apple M2/M3/M4 Pro or Max 24-48 GB",
      "minMemoryGB": 20,
      "maxMemoryGB": 56,
      "model": "qwen2.5-coder:14b",
      "fallbackModels": ["qwen3:8b-q8_0", "qwen3:8b"],
      "quantization": "Q4_K_M",
      "numCtx": 16384,
      "maxCtx": 32768,
      "minCtx": 8192,
      "numParallel": 4,
      "kvCacheType": "q8_0",
      "flashAttention": true,
      "numGPU": 999,
      "metalBudgetGB": 20,
      "minFreeGB": 3.0,
      "estimatedWeightsGB": 9.0,
      "kvBytesPerTokenF16": 196608,
      "computeOverheadGB": 0.9
    },
    {
      "id": "apple-64-96gb",
      "description": "Apple Max / Ultra 64-96 GB",
      "minMemoryGB": 56,
      "maxMemoryGB": 100,
      "model": "qwen3:32b",
      "fallbackModels": ["qwen2.5:32b"],
      "quantization": "Q4_K_M",
      "numCtx": 32768,
      "maxCtx": 65536,
      "minCtx": 8192,
      "numParallel": 6,
      "kvCacheType": "q8_0",
      "flashAttention": true,
      "numGPU": 999,
      "metalBudgetGB": 46,
      "minFreeGB": 6.0,
      "estimatedWeightsGB": 20.0,
      "kvBytesPerTokenF16": 262144,
      "computeOverheadGB": 1.5
    },
    {
      "id": "apple-128gb-plus",
      "description": "Apple Ultra 128 GB+",
      "minMemoryGB": 100,
      "maxMemoryGB": 100000,
      "model": "llama3.3:70b",
      "fallbackModels": ["qwen3:32b"],
      "quantization": "Q4_K_M",
      "numCtx": 32768,
      "maxCtx": 65536,
      "minCtx": 8192,
      "numParallel": 6,
      "kvCacheType": "q8_0",
      "flashAttention": true,
      "numGPU": 999,
      "metalBudgetGB": 96,
      "minFreeGB": 10.0,
      "estimatedWeightsGB": 43.0,
      "kvBytesPerTokenF16": 327680,
      "computeOverheadGB": 2.5
    }
  ]
}
"""#
}
