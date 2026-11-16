#!/usr/bin/env bash
# Builds LocalLLM.app (arm64, Release), embeds the Ollama engine, seeds the Git auto-update
# repository, signs everything and produces dist/LocalLLM-M3.dmg with an /Applications link.
#
# Usage:
#   ./build_dmg.sh
#
# Environment overrides:
#   SIGN_IDENTITY   codesign identity ("-" = ad-hoc, default). Use "Developer ID Application: …" to distribute.
#   NOTARY_PROFILE  notarytool keychain profile; when set (and SIGN_IDENTITY is a real identity) the DMG is notarized.
#   OLLAMA_BIN      path to an existing ollama binary (e.g. /opt/homebrew/bin/ollama) instead of downloading.
#   OLLAMA_VERSION  release tag to download (default: latest), e.g. v0.12.3
#   REMOTE_URL      Git remote the app keeps in sync with (default: this repo's origin or the LLMLX GitHub repo).
#   BRANCH          branch to track (default: main)
#   APP_VERSION     CFBundleShortVersionString (default: 1.0.<commit count>)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="LocalLLM"
BUNDLE_ID="com.llmlx.localllm"
DMG_NAME="LocalLLM-M3.dmg"
VOLUME_NAME="LocalLLM M3"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BRANCH="${BRANCH:-main}"
DEFAULT_REMOTE="https://github.com/rmrodriguezgit/LLMLX.git"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS required"
command -v swift >/dev/null || fail "Swift toolchain not found (xcode-select --install)"
command -v git   >/dev/null || fail "git not found"

# ---------------------------------------------------------------------------
# 1. Git: make sure the working repo points at the configured remote
# ---------------------------------------------------------------------------
if [[ ! -d .git ]]; then
  log "Initialising git repository"
  git init -q -b "$BRANCH"
fi
REMOTE_URL="${REMOTE_URL:-$(git remote get-url origin 2>/dev/null || echo "$DEFAULT_REMOTE")}"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo "uncommitted")"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  log "WARNING: working tree has uncommitted changes; the app will report commit $COMMIT"
fi
COMMIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
APP_VERSION="${APP_VERSION:-1.0.$COMMIT_COUNT}"
log "Remote: $REMOTE_URL  branch: $BRANCH  commit: ${COMMIT:0:12}  version: $APP_VERSION"

# Keep the embedded fallback config in sync with config/profiles.json
./scripts/embed_config.sh >/dev/null

# App icon (regenerated only if missing)
[[ -f assets/AppIcon.icns ]] || ./scripts/make_icns.sh

# Dashboard (TypeScript). web/dist is committed, so Node is optional.
if command -v npm >/dev/null 2>&1; then
  log "Building dashboard (TypeScript)"
  (cd web && { [[ -d node_modules ]] || npm ci --no-audit --no-fund >/dev/null; } && npm run build >/dev/null)
else
  log "npm not found; using committed web/dist"
fi
[[ -f web/dist/index.html ]] || fail "web/dist missing (run: cd web && npm install && npm run build)"

# ---------------------------------------------------------------------------
# 2. Compile (Release, arm64)
# ---------------------------------------------------------------------------
log "Compiling release build (arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || fail "binary not found at $BIN"

# ---------------------------------------------------------------------------
# 3. App bundle skeleton
# ---------------------------------------------------------------------------
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ollama"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp config/profiles.json "$APP/Contents/Resources/profiles.json"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R web/dist "$APP/Contents/Resources/web"
rm -f "$APP/Contents/Resources/web/app.js.map"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>LocalLLM</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$COMMIT_COUNT</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>LLMLX</string>
  <key>LLMLXCommit</key><string>$COMMIT</string>
  <key>LLMLXRemote</key><string>$REMOTE_URL</string>
  <key>LLMLXBranch</key><string>$BRANCH</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# 4. Embed the Ollama engine (arm64) in Contents/Resources/ollama/
# ---------------------------------------------------------------------------
OLLAMA_DIR="$APP/Contents/Resources/ollama"
if [[ -n "${OLLAMA_BIN:-}" ]]; then
  REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OLLAMA_BIN")"
  [[ -x "$REAL" ]] || fail "OLLAMA_BIN=$OLLAMA_BIN is not executable"
  log "Embedding local Ollama from $REAL"
  SRC_DIR="$(dirname "$REAL")"
  cp "$REAL" "$OLLAMA_DIR/ollama"
  # Runner libraries (ggml/metal) live next to the binary in lib/ for recent releases.
  if [[ -d "$SRC_DIR/lib" ]]; then
    cp -R "$SRC_DIR/lib" "$OLLAMA_DIR/lib"
    # Package managers (Homebrew) symlink into their prefix: materialise every symlink so the
    # bundle is self-contained (codesign rejects links that point outside the bundle).
    while IFS= read -r -d '' link; do
      rel="${link#"$OLLAMA_DIR/lib/"}"
      target="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$SRC_DIR/lib/$rel")"
      rm -f "$link"
      if [[ -f "$target" ]]; then cp "$target" "$link"; else log "Skipping dangling link lib/$rel"; fi
    done < <(find "$OLLAMA_DIR/lib" -type l -print0)
  fi
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  if [[ "${OLLAMA_VERSION:-latest}" == "latest" ]]; then
    BASE="https://github.com/ollama/ollama/releases/latest/download"
  else
    BASE="https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION"
  fi
  log "Downloading Ollama ($BASE/ollama-darwin.tgz)"
  curl -fL --retry 3 -o "$TMP/ollama-darwin.tgz" "$BASE/ollama-darwin.tgz"
  if curl -fsSL -o "$TMP/sha256sum.txt" "$BASE/sha256sum.txt"; then
    EXPECTED="$(grep 'ollama-darwin.tgz' "$TMP/sha256sum.txt" | awk '{print $1}' | head -1)"
    ACTUAL="$(shasum -a 256 "$TMP/ollama-darwin.tgz" | awk '{print $1}')"
    [[ -z "$EXPECTED" || "$EXPECTED" == "$ACTUAL" ]] || fail "Ollama checksum mismatch ($ACTUAL != $EXPECTED)"
    [[ -n "$EXPECTED" ]] && log "Checksum verified"
  fi
  tar -xzf "$TMP/ollama-darwin.tgz" -C "$OLLAMA_DIR"
  [[ -x "$OLLAMA_DIR/ollama" ]] || fail "ollama binary missing from archive"
fi
# Thin universal binaries to arm64 to save space.
while IFS= read -r -d '' f; do
  if lipo -info "$f" 2>/dev/null | grep -q "Architectures in the fat file"; then
    lipo "$f" -thin arm64 -output "$f.arm64" 2>/dev/null && mv "$f.arm64" "$f" || rm -f "$f.arm64"
  fi
done < <(find "$OLLAMA_DIR" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)
lipo -archs "$OLLAMA_DIR/ollama" | grep -q arm64 || fail "embedded ollama is not arm64"
if ! find "$OLLAMA_DIR" -name 'libollama_xgrammar*' | grep -q .; then
  log "WARNING: this Ollama build has no libollama_xgrammar: requests with JSON schema / structured output"
  log "         will fail with 501. Build without OLLAMA_BIN to embed the official release."
fi
log "Ollama embedded: $("$OLLAMA_DIR/ollama" --version 2>/dev/null | tail -1 || echo unknown)"

# ---------------------------------------------------------------------------
# 5. Seed repository: the app clones from this bundle on first launch (offline),
#    then re-points origin at REMOTE_URL for continuous sync.
# ---------------------------------------------------------------------------
if git rev-parse HEAD >/dev/null 2>&1; then
  log "Creating Git seed bundle ($BRANCH)"
  git bundle create "$APP/Contents/Resources/seed.bundle" "$BRANCH" >/dev/null 2>&1 \
    || git bundle create "$APP/Contents/Resources/seed.bundle" HEAD >/dev/null
else
  log "WARNING: no commits yet; the app will clone $REMOTE_URL on first launch"
fi

# ---------------------------------------------------------------------------
# 6. Code signing (inside-out: engine binaries/libs first, then the app)
# ---------------------------------------------------------------------------
xattr -cr "$APP" 2>/dev/null || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  log "Ad-hoc signing (local use; set SIGN_IDENTITY for distribution)"
  while IFS= read -r -d '' f; do
    codesign --force --sign - "$f" >/dev/null 2>&1 || true
  done < <(find "$OLLAMA_DIR" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)
  codesign --force --sign - "$APP"
else
  log "Signing with identity: $SIGN_IDENTITY (hardened runtime)"
  while IFS= read -r -d '' f; do
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$f"
  done < <(find "$OLLAMA_DIR" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

# ---------------------------------------------------------------------------
# 7. DMG with /Applications shortcut
# ---------------------------------------------------------------------------
log "Creating $DMG_NAME"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Volume icon shown when the DMG is mounted
cp assets/AppIcon.icns "$STAGE/.VolumeIcon.icns"
rm -f "$DIST/$DMG_NAME"
RW="$(mktemp -d)/rw.dmg"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null 2>&1
rm -rf "$STAGE"
# The "custom icon" flag must be set on the mounted volume root, then the image is compressed.
MNT="$(hdiutil attach -nobrowse -noautoopen "$RW" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
if [[ -n "$MNT" && -d "$MNT" ]]; then
  command -v SetFile >/dev/null && SetFile -a C "$MNT" || true
  hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
fi
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DIST/$DMG_NAME" >/dev/null 2>&1
rm -f "$RW"
# Custom Finder icon for the .dmg file itself (local only; GitHub/HTTP downloads drop it)
osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.setIconForFileOptions(\$.NSImage.alloc.initWithContentsOfFile('$ROOT/assets/AppIcon.icns'), '$DIST/$DMG_NAME', 0)" >/dev/null 2>&1 || true
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DIST/$DMG_NAME"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    log "Notarizing (profile $NOTARY_PROFILE)"
    xcrun notarytool submit "$DIST/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/$DMG_NAME"
  fi
fi

SIZE="$(du -h "$DIST/$DMG_NAME" | awk '{print $1}')"
log "Done: $DIST/$DMG_NAME ($SIZE)"
echo "    Install: open the DMG, drag LocalLLM to Applications, launch it (menu bar icon)."
echo "    API:     http://127.0.0.1:11500/v1  (OpenAI)  |  http://127.0.0.1:11500/api  (Ollama)"
