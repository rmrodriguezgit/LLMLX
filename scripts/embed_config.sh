#!/usr/bin/env bash
# Regenerates Sources/LocalLLM/EmbeddedConfig.swift from config/profiles.json.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  printf '// Generated from config/profiles.json — last-resort fallback when no profiles.json is found.\n// Regenerate with: ./scripts/embed_config.sh\nenum EmbeddedConfig {\n    static let json = #"""\n'
  cat config/profiles.json
  printf '"""#\n}\n'
} > Sources/LocalLLM/EmbeddedConfig.swift
echo "EmbeddedConfig.swift regenerated"
