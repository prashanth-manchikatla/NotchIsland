#!/bin/bash
#
# Build Hoverbird.app using only the Command Line Tools' Swift compiler.
# (No Xcode and no SwiftPM needed.)
#
#   ./Scripts/build.sh            # build  -> build/Hoverbird.app
#   ./Scripts/build.sh --install  # build, copy to /Applications, (re)launch
#   ./Scripts/build.sh --debug    # unoptimised build (faster compile)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Hoverbird"
BUNDLE_ID="app.hoverbird.mac"
VERSION="1.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
MIN_MACOS="14.0"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos${MIN_MACOS}"

INSTALL=0
OPT_FLAGS=(-O -whole-module-optimization)
CONFIG="release"
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --debug) OPT_FLAGS=(-Onone -g); CONFIG="debug" ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

BUILD_DIR="$ROOT/.build/manual/$CONFIG"
MOD_DIR="$BUILD_DIR/modules"
LIB_DIR="$BUILD_DIR/lib"
STAMP_DIR="$BUILD_DIR/stamps"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"
mkdir -p "$MOD_DIR" "$LIB_DIR" "$STAMP_DIR" "$OUT_DIR"
# Test builds in build/ shouldn't appear next to the installed app in Spotlight / Launchpad.
touch "$OUT_DIR/.metadata_never_index"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- Pick an SDK whose Swift interfaces this compiler can read -----------------
pick_sdk() {
  local cache="$ROOT/.build/manual/sdk.txt"
  local compiler_id
  compiler_id="$(swiftc --version 2>&1 | head -1)"
  if [[ -f "$cache" ]] && [[ "$(head -1 "$cache")" == "$compiler_id" ]] && [[ -d "$(sed -n 2p "$cache")" ]]; then
    sed -n 2p "$cache"; return
  fi
  local candidates=()
  [[ -n "${SDKROOT:-}" ]] && candidates+=("$SDKROOT")
  local clt="/Library/Developer/CommandLineTools/SDKs"
  for s in "$clt"/MacOSX26*.sdk "$clt"/MacOSX.sdk "$(xcrun --show-sdk-path 2>/dev/null || true)" "$clt"/MacOSX*.sdk; do
    [[ -d "$s" ]] && candidates+=("$s")
  done
  local probe="$ROOT/.build/manual/sdk-probe"
  mkdir -p "$probe"
  echo 'import SwiftUI; let _ = Text("x")' > "$probe/probe.swift"
  for sdk in "${candidates[@]}"; do
    if swiftc -typecheck -sdk "$sdk" -target "$TARGET" "$probe/probe.swift" >/dev/null 2>&1; then
      printf '%s\n%s\n' "$compiler_id" "$sdk" > "$cache"
      echo "$sdk"; return
    fi
  done
  echo "No usable macOS SDK found for $(swiftc --version 2>&1 | head -1)" >&2
  exit 1
}
SDK="$(pick_sdk)"
log "Using SDK: $SDK"

COMMON_FLAGS=(-sdk "$SDK" -target "$TARGET" "${OPT_FLAGS[@]}" -module-cache-path "$BUILD_DIR/module-cache")

# --- Vendored dependency modules (rebuilt only when their sources change) ------
build_module() {
  local name="$1"; shift
  local lang="$1"; shift
  local src_dir="$ROOT/Vendor/$name"
  local sources=()
  while IFS= read -r -d '' f; do sources+=("$f"); done < <(find "$src_dir" -name '*.swift' -print0 | sort -z)
  local hash
  hash="$( (printf '%s\n' "${COMMON_FLAGS[@]}" "$lang"; cat "${sources[@]}") | shasum -a 256 | cut -d' ' -f1)"
  if [[ -f "$STAMP_DIR/$name" ]] && [[ "$(cat "$STAMP_DIR/$name")" == "$hash" ]] \
     && [[ -f "$LIB_DIR/lib$name.a" ]] && [[ -d "$MOD_DIR/$name.swiftmodule" || -f "$MOD_DIR/$name.swiftmodule" ]]; then
    return
  fi
  log "Compiling module $name (${#sources[@]} files)"
  swiftc "${COMMON_FLAGS[@]}" -swift-version "$lang" -suppress-warnings \
    -module-name "$name" -parse-as-library \
    -I "$MOD_DIR" \
    -emit-module -emit-module-path "$MOD_DIR/$name.swiftmodule" \
    -emit-library -static -o "$LIB_DIR/lib$name.a" \
    "${sources[@]}"
  echo "$hash" > "$STAMP_DIR/$name"
}

build_module Defaults 5
build_module KeyboardShortcuts 5
build_module LaunchAtLogin 5
build_module SwiftUIIntrospect 5
build_module SkyLightWindow 5
build_module MacroVisionKit 6

# --- The app itself --------------------------------------------------------------
APP_SOURCES=()
while IFS= read -r -d '' f; do APP_SOURCES+=("$f"); done < <(find "$ROOT/boringNotch" -name '*.swift' -not -path '*/Preview Content/*' -print0 | sort -z)
log "Compiling $APP_NAME (${#APP_SOURCES[@]} files, $CONFIG)"
COMPILE_LOG="$BUILD_DIR/compile.log"
set +e
swiftc "${COMMON_FLAGS[@]}" -swift-version 5 \
  -module-name "$APP_NAME" -parse-as-library \
  -I "$MOD_DIR" -L "$LIB_DIR" \
  -lDefaults -lKeyboardShortcuts -lLaunchAtLogin -lSwiftUIIntrospect -lSkyLightWindow -lMacroVisionKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -Xlinker -dead_strip \
  -o "$BUILD_DIR/$APP_NAME" \
  "${APP_SOURCES[@]}" > "$COMPILE_LOG" 2>&1
STATUS=$?
set -e
WARNINGS="$(grep -c ': warning:' "$COMPILE_LOG" || true)"
if [[ $STATUS -ne 0 ]]; then
  grep -E ': error:' -A3 "$COMPILE_LOG" | head -150 >&2 || cat "$COMPILE_LOG" | tail -60 >&2
  echo "Build FAILED ($(grep -c ': error:' "$COMPILE_LOG" || true) errors, $WARNINGS warnings). Full log: $COMPILE_LOG" >&2
  exit 1
fi
log "Compiled OK ($WARNINGS warnings, see $COMPILE_LOG)"

# --- Assemble the .app bundle -----------------------------------------------------
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Resources
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT"/Resources/Images/*.png "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT/boringNotch/boring.m4a" "$APP/Contents/Resources/"
cp "$ROOT/mediaremote-adapter/mediaremote-adapter.pl" "$APP/Contents/Resources/"
ditto "$ROOT/mediaremote-adapter/MediaRemoteAdapterTestClient" "$APP/Contents/Resources/MediaRemoteAdapterTestClient"
# License files ship inside every copy of the app: the GPL-3.0 text, Hoverbird's notices
# and the third-party licenses (GPL-3.0 §4 and §6; the MIT and BSD licenses also need their
# notices in binary copies). Settings › About shows them.
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY_LICENSES" "$APP/Contents/Resources/"
KS_BUNDLE="$APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"
mkdir -p "$KS_BUNDLE"
cp -R "$ROOT/Vendor/KeyboardShortcuts/Localization/"*.lproj "$KS_BUNDLE/"
# Frameworks
ditto "$ROOT/mediaremote-adapter/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"

# --- Code signing -------------------------------------------------------------------
KEYCHAIN="$HOME/Library/Keychains/hoverbird-codesign.keychain-db"
SIGN_ARGS=(--sign -)
if [[ -f "$KEYCHAIN" && -f "$ROOT/.signing/keychain.pass" ]]; then
  security unlock-keychain -p "$(cat "$ROOT/.signing/keychain.pass")" "$KEYCHAIN"
  IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/Hoverbird Local Signing/ {print $2; exit}')"
  if [[ -n "$IDENTITY" ]]; then
    SIGN_ARGS=(--sign "$IDENTITY" --keychain "$KEYCHAIN")
  fi
fi
sign_bundle() {
  codesign --force --timestamp=none "$@" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework" 2>/dev/null &&
  codesign --force --timestamp=none "$@" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null
}
if [[ "${SIGN_ARGS[1]}" != "-" ]] && sign_bundle "${SIGN_ARGS[@]}"; then
  log "Signed with local identity ${SIGN_ARGS[1]}"
else
  # Ad-hoc signature: works everywhere locally. macOS ties privacy permissions to
  # this exact build, so after a rebuild re-enable Hoverbird in Privacy settings.
  sign_bundle --sign -
  log "Signed ad-hoc"
fi
codesign --verify --strict "$APP"

SIZE="$(du -sh "$APP" | cut -f1)"
log "Built $APP ($SIZE)"
# Not an installed app: keep it out of LaunchServices so only /Applications/Hoverbird.app is listed.
[[ "$INSTALL" == 1 ]] || "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

# --- Install + launch ----------------------------------------------------------------
if [[ "$INSTALL" == 1 ]]; then
  DEST="/Applications/$APP_NAME.app"
  if pgrep -x "$APP_NAME" >/dev/null; then
    log "Quitting running $APP_NAME"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
    pkill -x "$APP_NAME" 2>/dev/null || true
  fi
  log "Installing to $DEST"
  rm -rf "$DEST"
  # Move (not copy): a second Hoverbird.app left in build/ shows up in Spotlight/Launchpad.
  mv "$APP" "$DEST"
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  log "Launched $DEST"
fi
