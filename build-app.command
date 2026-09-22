#!/usr/bin/env bash
#
# build-app.command — assemble GopForge.app (a proper macOS .app bundle)
#
# Run this ON THE MAC, in the folder that also holds gopforge.sh,
# gopforge-gui.command and (optionally) AppIcon.png:
#
#     bash build-app.command
#
# It produces GopForge.app next to this script and reveals it in Finder.
#
# It picks the best UI your Mac can compile, in this order:
#   1. Native Swift app (PREFERRED) — one window: buttons + a colored, streaming
#      log. Needs Apple's Command Line Tools (free):  xcode-select --install
#   2. Platypus "Text Window" app — log in-app, input via dialogs. Needs the
#      Platypus CLI (https://sveinbjorn.org/platypus → Install Command Line Tool).
#   3. Terminal-log fallback — a plain .app whose launcher shows the log in Terminal.
#
# This changes NONE of GopForge's logic — it bundles the unchanged gopforge.sh
# (and, for the fallbacks, gopforge-gui.command) and calls them.
#
# SPDX-License-Identifier: MIT
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/GopForge.app"
APPNAME="GopForge"
VERSION="0.8.1"
BUNDLE_ID="com.kurdtnervanna.gopforge"

command -v osascript >/dev/null 2>&1 || { echo "This builder requires macOS."; exit 1; }
for f in gopforge.sh gopforge-gui.command; do
  [ -f "$HERE/$f" ] || { echo "Missing $f next to build-app.command — keep them together."; exit 1; }
done

# ----------------------------------------------------------------------------
# icon: use AppIcon.icns if present, else build one from AppIcon.png
# ----------------------------------------------------------------------------
ICNS=""
if [ -f "$HERE/AppIcon.icns" ]; then
  ICNS="$HERE/AppIcon.icns"
elif [ -f "$HERE/AppIcon.png" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  echo "Building AppIcon.icns from AppIcon.png…"
  ICONSET="$HERE/.AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for pair in 16:16 16:32@2x 32:32 32:64@2x 128:128 128:256@2x 256:256 256:512@2x 512:512 512:1024@2x; do
    base="${pair%%:*}"; rest="${pair#*:}"; pxsz="${rest%%@*}"; sfx=""
    case "$rest" in *@2x) sfx="@2x";; esac
    sips -z "$pxsz" "$pxsz" "$HERE/AppIcon.png" --out "$ICONSET/icon_${base}x${base}${sfx}.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$HERE/AppIcon.icns" >/dev/null 2>&1; then ICNS="$HERE/AppIcon.icns"; fi
  rm -rf "$ICONSET"
fi
[ -n "$ICNS" ] && echo "Icon: $ICNS" || echo "Icon: (generic — add AppIcon.png to brand it)"

# writes Contents/Info.plist for a hand-assembled bundle (Swift/Terminal builds)
write_plist() {
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APPNAME}</string>
  <key>CFBundleDisplayName</key><string>${APPNAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key><string>${APPNAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST
}

# ----------------------------------------------------------------------------
# detect toolchains: swiftc (preferred, native one-window app) then Platypus
# ----------------------------------------------------------------------------
SWIFTC="$(command -v swiftc 2>/dev/null || true)"
[ -z "$SWIFTC" ] && SWIFTC="$(xcrun -f swiftc 2>/dev/null || true)"
PLAT="$(command -v platypus 2>/dev/null || true)"
for p in /usr/local/bin/platypus /opt/homebrew/bin/platypus "$HOME/bin/platypus"; do
  [ -z "$PLAT" ] && [ -x "$p" ] && PLAT="$p"
done
echo "swiftc:   ${SWIFTC:-NOT FOUND}"
echo "Platypus: ${PLAT:-NOT FOUND}"

rm -rf "$APP"

if [ -n "$SWIFTC" ] && [ -f "$HERE/GopForge.swift" ]; then
  # ==========================================================================
  # PREFERRED: native single-window AppKit app (buttons + colored log)
  # ==========================================================================
  echo "Building native Swift app…"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  write_plist
  if "$SWIFTC" -O -o "$APP/Contents/MacOS/${APPNAME}" "$HERE/GopForge.swift" -framework AppKit; then
    chmod +x "$APP/Contents/MacOS/${APPNAME}"
    cp "$HERE/gopforge.sh" "$APP/Contents/Resources/gopforge.sh"; chmod +x "$APP/Contents/Resources/gopforge.sh"
    [ -n "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
    MODE_NOTE="native Swift app (one window, buttons, colored log)"
  else
    echo "swiftc failed — falling back."; rm -rf "$APP"; SWIFTC=""
  fi
fi

if [ ! -d "$APP" ] && [ -n "$PLAT" ]; then
  # ==========================================================================
  # FALLBACK 1: Platypus "Text Window" app (in-app log, but no custom buttons)
  # ==========================================================================
  echo "Building with Platypus (in-app log window): $PLAT"
  args=( -y -a "$APPNAME" -o "Text Window" -p "/bin/bash"
         -V "$VERSION" -u "KurdtNervanna" -I "$BUNDLE_ID"
         -f "$HERE/gopforge.sh" )
  [ -n "$ICNS" ] && args+=( -i "$ICNS" )
  "$PLAT" "${args[@]}" "$HERE/gopforge-gui.command" "$APP"
  MODE_NOTE="Platypus text-window (log in-app; input via dialogs)"
fi

if [ ! -d "$APP" ]; then
  # ==========================================================================
  # FALLBACK 2: plain .app whose launcher opens Terminal for the log
  # ==========================================================================
  echo "No swiftc or Platypus — building the Terminal-log fallback app."
  echo "  For the native one-window app, install Apple's Command Line Tools:"
  echo "     xcode-select --install"
  echo "  then re-run:  bash build-app.command"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  write_plist
  cat > "$APP/Contents/MacOS/${APPNAME}" <<'LAUNCH'
#!/bin/bash
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
GUI="$RES/gopforge-gui.command"
CMD="clear; exec '$GUI'"
/usr/bin/osascript >/dev/null 2>&1 <<AS
tell application "Terminal"
  activate
  do script "$CMD"
end tell
AS
LAUNCH
  chmod +x "$APP/Contents/MacOS/${APPNAME}"
  cp "$HERE/gopforge.sh"          "$APP/Contents/Resources/gopforge.sh"
  cp "$HERE/gopforge-gui.command" "$APP/Contents/Resources/gopforge-gui.command"
  chmod +x "$APP/Contents/Resources/gopforge.sh" "$APP/Contents/Resources/gopforge-gui.command"
  [ -n "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  MODE_NOTE="Terminal log (install Xcode CLT for the native app)"
fi

# ----------------------------------------------------------------------------
# finalize
# ----------------------------------------------------------------------------
xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true
touch "$APP"
echo "Done → $APP  [$MODE_NOTE]"
open -R "$APP" >/dev/null 2>&1 || true
osascript >/dev/null 2>&1 <<AS || true
display dialog "GopForge.app is ready in:

$HERE

Mode: $MODE_NOTE

Double-click it to test." buttons {"OK"} default button "OK" with title "GopForge — build complete"
AS
