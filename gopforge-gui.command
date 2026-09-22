#!/usr/bin/env bash
#
# gopforge-gui.command — a native macOS front-end for gopforge.sh
#
# This is ONLY a GUI wrapper. It changes none of GopForge's logic: it collects
# your choices with the same kind of native dialogs Macschrauber's Rom Dump uses
# (AppleScript / osascript) and then calls gopforge.sh with the matching flags.
# All the real work — fetching, injecting, and validating — is still done by
# gopforge.sh exactly as on the command line.
#
# Double-click this file in Finder (it opens in Terminal, where you can watch the
# full validation log). Requires macOS. SPDX-License-Identifier: MIT
set -euo pipefail

# ----------------------------------------------------------------------------
# locate gopforge.sh next to this wrapper
# ----------------------------------------------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
GOP="$HERE/gopforge.sh"

# runner: prefer the executable bit, fall back to `bash`
run_gop() {
  if [ -x "$GOP" ]; then "$GOP" "$@"; else bash "$GOP" "$@"; fi
}

# ----------------------------------------------------------------------------
# osascript dialog helpers (dynamic text passed as argv to avoid quoting hell)
# ----------------------------------------------------------------------------
TITLE="GopForge"

osa() { osascript "$@"; }   # thin wrapper so failures don't trip `set -e` when guarded

msg() { # msg <text> [icon: note|caution|stop]
  local icon="${2:-note}"
  osa - "$1" "$TITLE" "$icon" <<'AS' >/dev/null 2>&1 || true
on run argv
  set t to item 1 of argv
  set ttl to item 2 of argv
  set ic to item 3 of argv
  if ic is "stop" then
    display dialog t buttons {"OK"} default button "OK" with title ttl with icon stop
  else if ic is "caution" then
    display dialog t buttons {"OK"} default button "OK" with title ttl with icon caution
  else
    display dialog t buttons {"OK"} default button "OK" with title ttl with icon note
  end if
end run
AS
}

confirm() { # confirm <text> <okLabel>  -> prints "OK" or "CANCEL"
  osa - "$1" "$2" "$TITLE" <<'AS' 2>/dev/null || echo CANCEL
on run argv
  try
    set r to display dialog (item 1 of argv) buttons {"Cancel", (item 2 of argv)} default button (item 2 of argv) with title (item 3 of argv) with icon caution
    return button returned of r
  on error
    return "CANCEL"
  end try
end run
AS
}

pick_file() { # -> POSIX path or "CANCEL"
  osa <<'AS' 2>/dev/null || echo CANCEL
try
  set f to choose file with prompt "Select your dumped Mac Pro BootROM (.rom or .bin)"
  return POSIX path of f
on error
  return "CANCEL"
end try
AS
}

pick_save() { # pick_save <defaultName> -> POSIX path or "CANCEL"
  osa - "$1" <<'AS' 2>/dev/null || echo CANCEL
on run argv
  try
    set f to choose file name with prompt "Save the prepared ROM as:" default name (item 1 of argv)
    return POSIX path of f
  on error
    return "CANCEL"
  end try
end run
AS
}

main_menu() { # -> one of: PREPARE CHECK FETCH CANCEL
  osa <<'AS' 2>/dev/null || echo CANCEL
try
  set opts to {"Prepare a ROM  (inject EnableGop)", "Inspect a ROM  (check only)", "Download tools  (fetch)"}
  set c to choose from list opts with title "GopForge" with prompt "What would you like to do?" default items {item 1 of opts} OK button name "Continue" cancel button name "Quit"
  if c is false then return "CANCEL"
  set choice to item 1 of c
  if choice starts with "Prepare" then
    return "PREPARE"
  else if choice starts with "Inspect" then
    return "CHECK"
  else
    return "FETCH"
  end if
on error
  return "CANCEL"
end try
AS
}

pick_variant() { # -> STANDARD | DIRECT | CANCEL
  osa <<'AS' 2>/dev/null || echo CANCEL
try
  set r to display dialog "Which EnableGop build?

• Standard — renders faster; the right choice for most GPUs.
• Direct — for GPUs that need DirectGopRendering (try this if the standard build gave no boot screen)." buttons {"Cancel", "Direct", "Standard"} default button "Standard" with title "GopForge" with icon note
  return button returned of r
on error
  return "CANCEL"
end try
AS
}

reveal() { open -R "$1" >/dev/null 2>&1 || true; }

# ----------------------------------------------------------------------------
# sanity: macOS + gopforge.sh present
# ----------------------------------------------------------------------------
if ! command -v osascript >/dev/null 2>&1; then
  echo "This GUI wrapper requires macOS (osascript). On Linux/Windows, use gopforge.sh directly." >&2
  exit 1
fi
if [ ! -f "$GOP" ]; then
  msg "Could not find gopforge.sh next to this app. Keep gopforge-gui.command in the same folder as gopforge.sh." stop
  exit 1
fi

clear 2>/dev/null || true
echo "GopForge GUI — the log below is produced by gopforge.sh (unchanged)."
echo

# ----------------------------------------------------------------------------
# main menu
# ----------------------------------------------------------------------------
MODE="$(main_menu)"
case "$MODE" in
  CANCEL|"") exit 0 ;;
esac

# ----------------------------------------------------------------------------
# CHECK
# ----------------------------------------------------------------------------
if [ "$MODE" = "CHECK" ]; then
  ROM="$(pick_file)"; [ "$ROM" = "CANCEL" ] && exit 0
  echo "== Inspecting: $ROM =="
  if run_gop --check "$ROM"; then
    msg "Inspection complete — see the details in the Terminal window." note
  else
    msg "Inspection reported a problem — see the Terminal window." caution
  fi
  exit 0
fi

# ----------------------------------------------------------------------------
# FETCH
# ----------------------------------------------------------------------------
if [ "$MODE" = "FETCH" ]; then
  echo "== Downloading EnableGop.ffs + DXEInject into ./tools =="
  if run_gop --fetch; then
    msg "Dependencies downloaded into the tools/ folder." note
  else
    msg "Download failed — see the Terminal window." caution
  fi
  exit 0
fi

# ----------------------------------------------------------------------------
# PREPARE (inject) — the main flow
# ----------------------------------------------------------------------------
ROM="$(pick_file)"; [ "$ROM" = "CANCEL" ] && exit 0

VAR="$(pick_variant)"; [ "$VAR" = "CANCEL" ] && exit 0
VARIANT_FLAG=""; VARIANT_NAME="Standard"
if [ "$VAR" = "Direct" ]; then VARIANT_FLAG="--direct"; VARIANT_NAME="Direct (EnableGopDirect)"; fi

# suggest a default output name next to the input
base="$(basename "$ROM")"
default_out="${base%.*}-enablegop.rom"
OUT="$(pick_save "$default_out")"; [ "$OUT" = "CANCEL" ] && exit 0

# summary + safety confirmation (gopforge.sh runs with -y after this)
SUMMARY="Prepare a boot ROM with EnableGop?

  Input   : $ROM
  Variant : $VARIANT_NAME
  Output  : $OUT

This writes a NEW file and never touches your input. It does NOT flash your
hardware — you still flash the result with Macschrauber's Rom Dump, and only
if GopForge reports success.

Flashing a Mac Pro boot ROM can brick the machine. Keep an untouched backup
and a hardware recovery path (CH341A + clip, or a Matt card) before flashing."
if [ "$(confirm "$SUMMARY" "Prepare")" != "Prepare" ]; then exit 0; fi

echo "== Preparing: $ROM  ($VARIANT_NAME) =="
if run_gop --inject "$ROM" -o "$OUT" $VARIANT_FLAG --force -y; then
  if [ "$(confirm "Prepared ROM ready:

$OUT

Next: inspect it in UEFITool 0.25.1 (EnableGop present once, serial + NVRAM
intact), then flash it with Macschrauber's Rom Dump and let it verify.

Reveal the file in Finder?" "Reveal")" = "Reveal" ]; then
    reveal "$OUT"
  fi
else
  msg "GopForge did NOT produce a valid ROM — do not flash anything. See the Terminal window for the reason." stop
fi
