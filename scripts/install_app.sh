#!/usr/bin/env bash
# Recompila LocalLLM y reemplaza la app instalada en /Applications por la nueva versión.
#
#   ./scripts/install_app.sh              # compila (descarga Ollama oficial) + instala + abre
#   SKIP_BUILD=1 ./scripts/install_app.sh # instala el dist/LocalLLM.app ya compilado
#
# Conserva tus datos (~/Library/Application Support/LocalLLM): métricas, modelo elegido,
# repositorio local y modelos descargados (~/.ollama/models).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.llmlx.localllm"
TARGET="/Applications/LocalLLM.app"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  ./build_dmg.sh
fi
[[ -d dist/LocalLLM.app ]] || { echo "dist/LocalLLM.app no existe; ejecuta ./build_dmg.sh" >&2; exit 1; }

echo "==> Cerrando LocalLLM (espera a que terminen las peticiones en curso)"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
# Una versión auto-actualizada corre desde Application Support/LocalLLM/bin
pkill -TERM -f "Application Support/LocalLLM/bin/LocalLLM-" 2>/dev/null || true
for _ in $(seq 1 60); do
  pgrep -f "LocalLLM.app/Contents/MacOS/LocalLLM|Application Support/LocalLLM/bin/LocalLLM-" >/dev/null || break
  sleep 1
done

echo "==> Reemplazando $TARGET"
rm -rf "$TARGET"
ditto dist/LocalLLM.app "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
# Refresca el icono en Finder/Launchpad
touch "$TARGET"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1 || true

echo "==> Abriendo la nueva versión"
open "$TARGET"
sleep 4
curl -fsS http://127.0.0.1:11500/health 2>/dev/null | grep -E '"displayVersion"|"engine"' || echo "La app está arrancando; revisa el icono en la barra de menú."
