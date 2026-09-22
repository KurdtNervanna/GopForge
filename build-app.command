#!/usr/bin/env bash
#
# build-app.command — assemble GopForge.app (a proper macOS .app bundle)
#
# Run this ON THE MAC, in the folder that also holds gopforge.sh and
# gopforge-gui.command:
#
#     bash build-app.command
#
# (Using `bash …` avoids any lost exec-bit when the files came over a share.)
# It produces GopForge.app next to this script, with correct permissions, and
# reveals it in Finder. Because the app is built locally it carries no
# com.apple.quarantine, so it double-clicks without a Gatekeeper prompt.
#
# This changes NONE of GopForge's logic. The app bundles the unchanged
# gopforge.sh and the gopforge-gui.command front-end; double-clicking the app
# opens a Terminal window running that same GUI (so you see the full validation
# log), which in turn calls gopforge.sh with the flags you pick.
#
# SPDX-License-Identifier: MIT
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/GopForge.app"
APPNAME="GopForge"
VERSION="0.7.0"
BUNDLE_ID="com.kurdtnervanna.gopforge"

# macOS only
command -v osascript >/dev/null 2>&1 || { echo "This builder requires macOS."; exit 1; }

# required sources must sit next to this builder
for f in gopforge.sh gopforge-gui.command; do
  [ -f "$HERE/$f" ] || { echo "Missing $f next to build-app.command — keep them together."; exit 1; }
done

echo "Building $APPNAME.app …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- Info.plist -------------------------------------------------------------
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

# --- launcher: open a visible Terminal running the bundled GUI ---------------
cat > "$APP/Contents/MacOS/${APPNAME}" <<'LAUNCH'
#!/bin/bash
# GopForge.app launcher — run the bundled GUI in a visible Terminal so the full
# gopforge.sh validation log is shown (like Rom Dump's progress window).
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

# --- bundle the unchanged CLI + GUI -----------------------------------------
cp "$HERE/gopforge.sh"          "$APP/Contents/Resources/gopforge.sh"
cp "$HERE/gopforge-gui.command" "$APP/Contents/Resources/gopforge-gui.command"
chmod +x "$APP/Contents/Resources/gopforge.sh" "$APP/Contents/Resources/gopforge-gui.command"

# --- icon: use AppIcon.icns if present, else build one from AppIcon.png ------
if [ -f "$HERE/AppIcon.icns" ]; then
  cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "  • bundled AppIcon.icns"
elif [ -f "$HERE/AppIcon.png" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  echo "  • building AppIcon.icns from AppIcon.png"
  set="$HERE/.AppIcon.iconset"; rm -rf "$set"; mkdir -p "$set"
  for pair in 16:16 16:32@2x 32:32 32:64@2x 128:128 128:256@2x 256:256 256:512@2x 512:512 512:1024@2x; do
    base="${pair%%:*}"; rest="${pair#*:}"; pxsz="${rest%%@*}"
    suffix=""; case "$rest" in *@2x) suffix="@2x";; esac
    sips -z "$pxsz" "$pxsz" "$HERE/AppIcon.png" --out "$set/icon_${base}x${base}${suffix}.png" >/dev/null 2>&1
  done
  iconutil -c icns "$set" -o "$APP/Contents/Resources/AppIcon.icns" && echo "    done" || echo "    iconutil failed — using generic icon"
  rm -rf "$set"
else
  echo "  • no AppIcon.icns/.png found — using the generic app icon"
fi

# --- finalize ----------------------------------------------------------------
# ensure the bundle is not quarantined (it is local, but be explicit)
xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true
# nudge Finder/LaunchServices to refresh the bundle
touch "$APP"

echo "Done → $APP"
open -R "$APP" >/dev/null 2>&1 || true
osascript >/dev/null 2>&1 <<AS || true
display dialog "GopForge.app is ready in:

$HERE

Double-click it to test. It opens a Terminal window running the same GUI, which calls the unchanged gopforge.sh." buttons {"OK"} default button "OK" with title "GopForge — build complete"
AS
