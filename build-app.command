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
# PREFERRED build (in-app log window, just like Macschrauber's Rom Dump):
#   If Platypus's command-line tool is installed, the app is built as a Platypus
#   "Text Window" app — GopForge's status/log is shown INSIDE the app window.
#   Install Platypus once:  brew install --cask platypus
#   then open Platypus → Preferences → "Install Command Line Tool", and re-run.
#
# FALLBACK build (no Platypus):
#   A plain .app whose launcher opens a Terminal window for the log. Functional,
#   but the log is in Terminal rather than in-app.
#
# Either way this changes NONE of GopForge's logic — it bundles the unchanged
# gopforge.sh and the gopforge-gui.command front-end and calls them.
#
# SPDX-License-Identifier: MIT
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/GopForge.app"
APPNAME="GopForge"
VERSION="0.8.0"
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

# ----------------------------------------------------------------------------
# locate the Platypus CLI
# ----------------------------------------------------------------------------
PLAT="$(command -v platypus 2>/dev/null || true)"
for p in /usr/local/bin/platypus /opt/homebrew/bin/platypus; do
  [ -z "$PLAT" ] && [ -x "$p" ] && PLAT="$p"
done

rm -rf "$APP"

if [ -n "$PLAT" ]; then
  # ==========================================================================
  # PREFERRED: Platypus "Text Window" app — status/log shown inside the app
  # ==========================================================================
  echo "Building with Platypus (in-app log window): $PLAT"
  args=( -y -a "$APPNAME" -o "Text Window" -p "/bin/bash"
         -V "$VERSION" -u "KurdtNervanna" -I "$BUNDLE_ID"
         -f "$HERE/gopforge.sh" )
  [ -n "$ICNS" ] && args+=( -i "$ICNS" )
  # main script = the GUI front-end; its stdout streams into the app window
  "$PLAT" "${args[@]}" "$HERE/gopforge-gui.command" "$APP"
  MODE_NOTE="in-app log window (Platypus)"
else
  # ==========================================================================
  # FALLBACK: plain .app whose launcher opens Terminal for the log
  # ==========================================================================
  echo "Platypus CLI not found — building the Terminal-log fallback app."
  echo "  For the in-app log window (like Rom Dump), install Platypus:"
  echo "     brew install --cask platypus"
  echo "  then open Platypus → Preferences → Install Command Line Tool, and re-run this."
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
  MODE_NOTE="Terminal log (install Platypus for an in-app window)"
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
