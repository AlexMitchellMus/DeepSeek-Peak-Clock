#!/usr/bin/env bash
# Builds a Release copy of DeepSeek Peak Clock, signs it "to run locally", and puts
# an installer next to it in dist/.
#
#   ./tools/package.sh            → dist/DeepSeek Peak Clock.app + installer
#   ./tools/package.sh --no-clean → keep the previous dist/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

export TMPDIR="$ROOT/.tmp/hc"
export CLANG_MODULE_CACHE_PATH="$ROOT/.tmp/mc"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

if [ "${1:-}" != "--no-clean" ]; then rm -rf "$DIST"; fi
mkdir -p "$DIST"

echo "▸ regenerating project (picks up new sources / build number)"
if GEM_HOME="$ROOT/.tmp/gems" GEM_PATH="$ROOT/.tmp/gems" ruby -e "require 'xcodeproj'" >/dev/null 2>&1; then
  GEM_HOME="$ROOT/.tmp/gems" GEM_PATH="$ROOT/.tmp/gems" ruby "$ROOT/tools/generate-project.rb" >/dev/null
else
  echo "  xcodeproj gem not installed — using the committed project file"
fi

# Build from a neutral directory (not under $HOME): the Swift binaries embed
# absolute paths from the build, and building inside the user's folder would bake
# their account name into the shipped app.
BUILDROOT="${DS_BUILDROOT:-/private/tmp/deepseek-tracker-build}"
rm -rf "$BUILDROOT"
mkdir -p "$BUILDROOT"
ditto "$ROOT/native" "$BUILDROOT/native"

echo "▸ building Release (from $BUILDROOT)"
xcodebuild -project "$BUILDROOT/native/DeepSeekTracker.xcodeproj" -scheme DeepSeekTracker \
  -configuration Release -derivedDataPath "$BUILDROOT/dd" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build >/dev/null

BUILT="$BUILDROOT/dd/Build/Products/Release/DeepSeekTracker.app"
APP="$DIST/DeepSeek Peak Clock.app"
rm -rf "$APP"
ditto "$BUILT" "$APP"

# WidgetKit registers the extension of the app it is launched from. If the build
# folder copy stays around, the system can resolve the widget to that path and
# ignore the installed app — so remove it as soon as dist/ has its copy.
rm -rf "$BUILDROOT"

echo "▸ signing (local / ad-hoc, widget extension gets sandbox + network)"
codesign --force --sign - --generate-entitlement-der \
  --entitlements "$ROOT/native/Widget/DeepSeekTrackerWidget.entitlements" \
  "$APP/Contents/PlugIns/DeepSeekTrackerWidget.appex"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ entitlements on the widget extension"
codesign -d --entitlements - "$APP/Contents/PlugIns/DeepSeekTrackerWidget.appex" 2>&1 | sed 's/^/  /'

cat > "$DIST/Install DeepSeek Peak Clock.command" <<'INSTALL'
#!/bin/bash
# Double-click to install DeepSeek Peak Clock into /Applications and launch it.
set -e
cd "$(dirname "$0")"
APP="DeepSeek Peak Clock.app"
DEST="/Applications/$APP"
LEGACY="/Applications/DeepSeek Tracker.app"
EXT="$DEST/Contents/PlugIns/DeepSeekTrackerWidget.appex"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -d "$APP" ]; then
  echo "Can't find \"$APP\" next to this installer."
  read -r -p "Press return to close."
  exit 1
fi

echo "Quitting any running copy…"
pkill -x DeepSeekTracker 2>/dev/null || true
pkill -f "DeepSeek Peak Clock.app" 2>/dev/null || true
pkill -f "DeepSeekTrackerWidget" 2>/dev/null || true

echo "Installing into /Applications…"
# Remove the pre-rename app so macOS can't resolve the widget to it.
if [ -d "$LEGACY" ]; then
  echo "  removing old \"DeepSeek Tracker.app\"…"
  pkill -f "DeepSeek Tracker.app" 2>/dev/null || true
  "$LSREG" -u "$LEGACY" 2>/dev/null || true
  rm -rf "$LEGACY"
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# macOS resolves widgets by bundle id, and only one copy can win. Leftover
# registrations (a build folder, this dist copy, the Trash) make the widget
# disappear from the gallery, so drop every other copy's registration and keep
# only /Applications.
echo "Cleaning up old widget registrations…"
for OLD in "$PWD/$APP" "$HOME/.Trash/$APP" \
           "$PWD/.tmp/dd/Build/Products/Debug/DeepSeekTracker.app" \
           "$PWD/.tmp/dd/Build/Products/Release/DeepSeekTracker.app" \
           "$PWD/.tmp/dd-release/Build/Products/Release/DeepSeekTracker.app"; do
  [ -e "$OLD" ] && "$LSREG" -u "$OLD" 2>/dev/null || true
done
"$LSREG" -f "$DEST" 2>/dev/null || true
pluginkit -r "$EXT" 2>/dev/null || true
pluginkit -a "$EXT" 2>/dev/null || true
killall chronod 2>/dev/null || true

echo "Launching…"
open "$DEST"

echo
echo "Done. Now: right-click the desktop → Edit Widgets → search \"DeepSeek Peak Clock\"."
echo "If a widget on the desktop still shows the old design, right-click it"
echo "→ Remove Widget, then add it again from Edit Widgets."
echo "Metrics: status + latency work with no setup. Uptime/balance need the collector."
echo
read -r -p "Press return to close."
INSTALL
chmod +x "$DIST/Install DeepSeek Peak Clock.command"

cat > "$DIST/README.txt" <<'TXT'
DeepSeek Peak Clock — macOS widget
===============================

Install
  1. Double-click "Install DeepSeek Peak Clock.command" (it copies the app to
     /Applications and opens it). If macOS warns about the app, right-click the
     app → Open once.
  2. Right-click the desktop → "Edit Widgets…".
  3. Search "DeepSeek Peak Clock" and drag the size you want onto the desktop.

What it shows
  • Big countdown until the next off-peak (half-price) window starts.
  • Green "Off-peak · half price" or red "Peak pricing" state.
  • When off-peak, the countdown points at the next peak instead.
  • Schedule bar: the day's peak/off-peak windows in your time zone, with a "now" notch.
  • Live metrics straight from DeepSeek (status + measured latency).

Peak windows (UTC): 01:00–04:00 and 06:00–10:00. Everything else is off-peak at
half price, and weekends plus Chinese public holidays are off-peak all day.

Optional extras
  Status and latency need no setup. For 90-day uptime and your API balance, run the
  collector from the repo:  node collector/status-collector.mjs --serve 8787 --interval 60
  If DeepSeek can't be reached the row reads "Metrics offline"; the countdown still works.

Notes
  The app is signed "to run locally" (ad-hoc), not notarized. If macOS refuses to
  open it, right-click → Open, or run: xattr -dr com.apple.quarantine "/Applications/DeepSeek Peak Clock.app"
  Widgets need the app in /Applications and launched once before they appear.
TXT

echo "▸ dist/"
ls -la "$DIST"
du -sh "$APP"
