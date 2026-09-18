#!/usr/bin/env bash
#
# gopforge.sh (GopForge) — Guided EnableGop injection + validation for Mac Pro 4,1/5,1
#
# WHAT THIS DOES
#   Takes a *dumped* boot ROM, injects the EnableGop DXE driver into it, and
#   validates the result — producing a ready-to-flash .rom. It does NOT dump
#   and does NOT flash. Dumping and flashing are done with Macschrauber's
#   Rom Dump tool, which already does them safely.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#   - It never touches your original dump (always writes a new file).
#   - It never writes to your SPI flash / hardware.
#   - It refuses to hand you a ROM that failed validation.
#
# See README.md for the full workflow, prerequisites, and recovery notes.
#
# SPDX-License-Identifier: MIT
set -euo pipefail

VERSION="0.4.0"
PROG="$(basename "$0")"

# Default OpenCore release to pull EnableGop.ffs from (override with --oc-version).
OC_VERSION="1.0.7"
# Auto-fetch behaviour (set by flags in main()).
NO_FETCH="no"
# Default source for DXEInject (dosdude1). The host now serves this file over
# HTTPS (Cloudflare), so it is safe to fetch by default. It is still a
# third-party, unsigned executable: its sha256 is pinned on first fetch (TOFU)
# and a later change is refused. Override with --dxeinject-url, or supply the
# binary yourself with --dxeinject / TOOLS_DIR.
DXEINJECT_URL="https://dosdude1.com/apps/DXEInject.zip"
TOOLS_DIR="./tools"

# ----------------------------------------------------------------------------
# pretty output
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""
fi
# temp-dir cleanup: track dirs and remove them once, on exit
_CLEANUP_DIRS=()
_cleanup() { local d; for d in "${_CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap _cleanup EXIT
mktempd() { local d; d="$(mktemp -d)"; _CLEANUP_DIRS+=("$d"); printf '%s' "$d"; }

say()  { printf '%s\n' "$*"; }
info() { printf '%s»%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
hr()   { printf '%s────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"; }

# ----------------------------------------------------------------------------
# usage
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
${C_BOLD}$PROG${C_RESET} v$VERSION — prepare a Mac Pro 4,1/5,1 boot ROM with EnableGop

${C_BOLD}USAGE${C_RESET}
  $PROG --fetch  [--dxeinject-url <https-url>]
  $PROG --check  <dump.rom>
  $PROG --inject <dump.rom> [-o out.rom] [options]

${C_BOLD}MODES${C_RESET}
  --fetch              Download dependencies into $TOOLS_DIR without injecting:
                       EnableGop.ffs from the official OpenCore release, and
                       DXEInject from dosdude1 (override with --dxeinject-url).
  --check <rom>        Inspect a ROM only: size, firmware sanity, EnableGop
                       present?, sha256. Use it BEFORE and AFTER injecting.
  --inject <rom>       Inject EnableGop into <rom> and validate the result.
                       Missing EnableGop.ffs is fetched automatically.

${C_BOLD}OPTIONS${C_RESET}
  -o, --output <file>     Output ROM path (default: <dump>-enablegop.rom)
  -f, --ffs <file>        Path to EnableGop.ffs (auto-fetched if absent)
      --dxeinject <p>     Path to the DXEInject binary (default: PATH/$TOOLS_DIR)
      --dxeinject-url <u> HTTPS URL to auto-fetch DXEInject (sha256-pinned, TOFU)
      --oc-version <v>    OpenCore release to pull EnableGop.ffs from (def: $OC_VERSION)
      --tools-dir <dir>   Where fetched tools go (default: ./tools)
      --no-fetch          Never download anything; require local files
      --force             Overwrite an existing output file
  -y, --yes               Non-interactive; assume yes at confirmations
  -h, --help              This help
      --version           Print version

${C_BOLD}DEPENDENCY NOTES${C_RESET}
  EnableGop.ffs is fetched over HTTPS from the official OpenCorePkg release
  (Utilities/EnableGop/). DXEInject is a separate dosdude1 tool, NOT part of
  OpenCore; it is fetched over HTTPS from dosdude1.com by default. It is an
  unsigned third-party executable, so its sha256 is pinned on first fetch (TOFU)
  and a later change is refused. To use your own copy instead, drop it in
  $TOOLS_DIR/, pass --dxeinject <path>, or override --dxeinject-url.

${C_BOLD}SAFETY${C_RESET}
  This tool only PREPARES a ROM. You still flash it with Macschrauber's
  Rom Dump. Never flash a ROM this tool reported as FAILED. Always keep an
  untouched backup of your original dump and a hardware recovery path
  (CH341A + SOIC-8 clip, or a "Matt card") before you flash.
EOF
}

# ----------------------------------------------------------------------------
# portability helpers (BSD/macOS + GNU/Linux)
# ----------------------------------------------------------------------------
file_size() { # bytes of $1
  if stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"      # BSD/macOS
  else stat -c%s "$1"; fi                                     # GNU
}

sha256_of() { # hex sha256 of $1
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else echo "unavailable"; fi
}

# perl is present by default on macOS and virtually all Linux; use it for
# binary scanning so we don't depend on GNU-only grep -P or strings -e.
have_perl() { command -v perl >/dev/null 2>&1; }

looks_like_firmware() { # 0 if a UEFI firmware volume header signature is present
  have_perl || return 0   # can't check → don't block
  perl -0777 -ne 'exit(/_FVH/ ? 0 : 1)' "$1"
}

# The EnableGop driver stores no readable "EnableGop" string; it is identified
# by its FFS file GUID, which is stable across versions and the Direct variant:
#   3FBA58B1-F8C0-41BC-ACD8-253043A3A17F
# stored little-endian in the image as the 16 raw bytes below.
EG_GUID_HEX="b158ba3fc0f8bc41acd8253043a3a17f"

contains_bytes() { # <file> <lowercase-hex> : 0 if the byte sequence occurs
  have_perl || return 2
  perl -e 'my($f,$h)=@ARGV; my $p=pack("H*",$h); local $/;
           open(my $fh,"<:raw",$f) or exit 2; my $d=<$fh>;
           exit(index($d,$p)>=0 ? 0 : 1)' "$1" "$2"
}

ffs_guid_hex() { # print the first 16 bytes of an .ffs as lowercase hex (its GUID)
  have_perl || return 2
  perl -e 'open(my $fh,"<:raw",$ARGV[0]) or exit 2; read($fh,my $b,16);
           print lc unpack("H*",$b)' "$1"
}

has_enablegop() { # 0 if the EnableGop FFS GUID is present in <rom>
  contains_bytes "$1" "$EG_GUID_HEX"
}

human() { # bytes → human
  awk -v b="$1" 'BEGIN{
    split("B KiB MiB GiB",u," "); i=1;
    while (b>=1024 && i<4){b/=1024;i++}
    printf (i==1 ? "%d %s" : "%.2f %s"), b, u[i]
  }'
}

# ----------------------------------------------------------------------------
# downloader — curl or wget, HTTPS only
# ----------------------------------------------------------------------------
download() { # download <url> <dest>
  local url="$1" dest="$2"
  case "$url" in
    https://*) ;;
    *) die "refusing to download over a non-HTTPS URL: $url" ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    curl -fL --proto '=https' --tlsv1.2 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -qO "$dest" "$url"
  else
    die "need 'curl' or 'wget' to download (neither found)"
  fi
}

# ----------------------------------------------------------------------------
# auto-fetch EnableGop.ffs from the official OpenCorePkg release (HTTPS)
#   The .ffs ships inside Utilities/EnableGop/ of the release zip.
# ----------------------------------------------------------------------------
fetch_enablegop_ffs() {
  local ver="$1" dest="$2"
  command -v unzip >/dev/null 2>&1 || die "need 'unzip' to extract the OpenCore release"
  mkdir -p "$(dirname "$dest")"
  local url="https://github.com/acidanthera/OpenCorePkg/releases/download/${ver}/OpenCore-${ver}-RELEASE.zip"
  local tmp; tmp="$(mktempd)"
  info "fetching EnableGop.ffs from OpenCore ${ver}…"
  info "$url"
  download "$url" "$tmp/oc.zip" || die "download failed: $url
     (check the version with --oc-version, or fetch EnableGop.ffs manually)"
  # Pick the standard EnableGop .ffs (the file is versioned, e.g.
  # Utilities/EnableGop/EnableGop_1.4.ffs). Exclude the "Direct" variant and
  # the Pre-release/dev builds; if several versions exist, take the newest.
  local member
  member="$(unzip -Z1 "$tmp/oc.zip" 2>/dev/null \
              | grep -iE '/EnableGop_[0-9][^/]*\.ffs$' \
              | grep -viE 'pre-release|dev' \
              | sort -V | tail -1 || true)"
  [ -n "$member" ] || die "no EnableGop_*.ffs found inside OpenCore-${ver}-RELEASE.zip
     (the release layout may have changed — extract EnableGop's .ffs manually)"
  info "selected $member"
  unzip -o -j "$tmp/oc.zip" "$member" -d "$(dirname "$dest")" >/dev/null \
    || die "failed to extract $member"
  local got
  got="$(dirname "$dest")/$(basename "$member")"
  [ "$got" != "$dest" ] && mv -f "$got" "$dest"
  [ -s "$dest" ] || die "fetched EnableGop.ffs is empty"
  ok "EnableGop.ffs → $dest ($(file_size "$dest") bytes, from OpenCore $ver)"
}

# ----------------------------------------------------------------------------
# auto-fetch DXEInject (executable) from a URL, with trust-on-first-use pinning
#   Defaults to dosdude1's HTTPS copy (see DXEINJECT_URL); override with
#   --dxeinject-url to point at a copy you trust. DXEInject is unsigned, so on
#   first fetch we record its sha256; on later fetches a changed binary is refused.
# ----------------------------------------------------------------------------
fetch_dxeinject() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  local tmp; tmp="$(mktempd)"
  info "fetching DXEInject from $url"
  download "$url" "$tmp/dl" || die "download failed: $url"

  # unzip if we got an archive, then locate a DXEInject executable inside
  local bin="$tmp/dl"
  if unzip -tq "$tmp/dl" >/dev/null 2>&1; then
    unzip -o -j "$tmp/dl" -d "$tmp/x" >/dev/null 2>&1 || true
    bin="$(find "$tmp/x" -type f -iname 'DXEInject*' ! -iname '*.txt' | head -1 || true)"
    [ -n "$bin" ] || die "no DXEInject binary found inside the downloaded archive"
  fi

  local sha; sha="$(sha256_of "$bin")"
  local lock="$TOOLS_DIR/.dxeinject.sha256"
  if [ -f "$lock" ]; then
    local pinned; pinned="$(cat "$lock")"
    if [ "$pinned" != "$sha" ]; then
      die "DXEInject sha256 changed since first fetch!
       pinned : $pinned
       now    : $sha
     Refusing to use it. If you intend to update, delete $lock and re-fetch."
    fi
    ok "DXEInject matches the pinned checksum"
  else
    mkdir -p "$TOOLS_DIR"; printf '%s\n' "$sha" > "$lock"
    warn "first fetch of DXEInject — pinning sha256 $sha"
    warn "this is a third-party executable; verify you trust its source"
  fi
  cp -f "$bin" "$dest"; chmod +x "$dest"
  ok "DXEInject → $dest"
}

# ----------------------------------------------------------------------------
# check mode
# ----------------------------------------------------------------------------
do_check() {
  local rom="$1"
  [ -f "$rom" ] || die "not found: $rom"
  [ -r "$rom" ] || die "not readable: $rom"
  local size; size="$(file_size "$rom")"
  [ "$size" -gt 0 ] || die "empty file: $rom"

  hr
  say "${C_BOLD}Inspecting${C_RESET} $rom"
  hr
  printf '  size    : %s (%s bytes)\n' "$(human "$size")" "$size"
  printf '  sha256  : %s\n' "$(sha256_of "$rom")"

  # size sanity — cMP boot ROM dumps are typically 2 MiB. We only warn.
  case "$size" in
    2097152) printf '  layout  : %s2 MiB — typical cMP dump%s\n' "$C_GRN" "$C_RESET" ;;
    1048576|4194304|8388608)
             printf '  layout  : %s%s — a power-of-two flash size%s\n' "$C_YEL" "$(human "$size")" "$C_RESET"
             warn "not the usual 2 MiB cMP dump size — double-check this is the right file" ;;
    *)       printf '  layout  : %s%s — unusual size%s\n' "$C_YEL" "$(human "$size")" "$C_RESET"
             warn "size is not a typical flash-chip size; is this really a full ROM dump?" ;;
  esac

  if looks_like_firmware "$rom"; then
    printf '  firmware: %sUEFI firmware volume signature (_FVH) found%s\n' "$C_GRN" "$C_RESET"
  else
    printf '  firmware: %sno _FVH signature found%s\n' "$C_RED" "$C_RESET"
    warn "this may not be a raw UEFI firmware dump"
  fi

  if has_enablegop "$rom"; then
    printf '  enablegop: %sPRESENT%s\n' "$C_YEL" "$C_RESET"
    say "  ${C_DIM}(injecting again would create a duplicate — inject only into a clean dump)${C_RESET}"
  else
    printf '  enablegop: %snot present%s\n' "$C_DIM" "$C_RESET"
  fi
  hr
}

# ----------------------------------------------------------------------------
# diff region reporter — summarise which byte ranges changed
# ----------------------------------------------------------------------------
report_diff() {
  local a="$1" b="$2"
  # cmp -l prints 1-based byte offsets that differ. Coalesce to min/max/count
  # without buffering the whole (potentially large) list.
  cmp -l "$a" "$b" 2>/dev/null | awk '
    NR==1 { min=$1 }
    { max=$1; n++ }
    END {
      if (n==0) { print "IDENTICAL"; exit }
      printf "CHANGED %d %d %d\n", n, min-1, max-1   # count, first_off, last_off (0-based)
    }' || true
}

# ----------------------------------------------------------------------------
# inject mode
# ----------------------------------------------------------------------------
do_inject() {
  local in="$1" out="$2" ffs="$3" dxe="$4" force="$5" yes="$6"

  # --- input dump ---------------------------------------------------------
  [ -f "$in" ] || die "input ROM not found: $in"
  [ -r "$in" ] || die "input ROM not readable: $in"
  local in_size; in_size="$(file_size "$in")"
  [ "$in_size" -gt 0 ] || die "input ROM is empty: $in"

  # --- EnableGop.ffs (auto-fetch if missing) ------------------------------
  if [ ! -f "$ffs" ]; then
    if [ "$NO_FETCH" = "yes" ]; then
      die "EnableGop.ffs not found: $ffs  (auto-fetch disabled with --no-fetch)"
    fi
    info "EnableGop.ffs not found locally — fetching it automatically"
    ffs="$TOOLS_DIR/EnableGop.ffs"
    [ -f "$ffs" ] || fetch_enablegop_ffs "$OC_VERSION" "$ffs"
  fi

  # --- DXEInject (uses a local copy if present, else auto-fetches) --------
  if [ -z "$dxe" ]; then
    if command -v DXEInject >/dev/null 2>&1; then dxe="$(command -v DXEInject)"
    elif [ -x "$TOOLS_DIR/DXEInject" ]; then dxe="$TOOLS_DIR/DXEInject"
    elif [ -x "./DXEInject" ]; then dxe="./DXEInject"
    fi
  fi
  if { [ -z "$dxe" ] || [ ! -x "$dxe" ]; } && [ -n "$DXEINJECT_URL" ] && [ "$NO_FETCH" != "yes" ]; then
    fetch_dxeinject "$DXEINJECT_URL" "$TOOLS_DIR/DXEInject"
    dxe="$TOOLS_DIR/DXEInject"
  fi
  [ -n "$dxe" ] && [ -x "$dxe" ] || die "DXEInject not available. It normally
     auto-fetches over HTTPS from dosdude1.com; this failed or was disabled.
     Provide it by:
       • dropping the binary in $TOOLS_DIR/ or on your PATH
       • passing it with --dxeinject <path>
       • pointing --dxeinject-url at an HTTPS copy you trust
       • re-running without --no-fetch to allow the default download
     DXEInject is a dosdude1 tool (dosdude1.com) and is NOT part of OpenCore.
     Manual alternative: insert EnableGop.ffs into the DXE volume with
     UEFITool 0.25.1 (newer UEFITool builds cannot write)."

  # --- output guard -------------------------------------------------------
  [ "$(cd "$(dirname "$in")" && pwd)/$(basename "$in")" != \
    "$(cd "$(dirname "$out")" 2>/dev/null && pwd)/$(basename "$out")" ] \
    || die "output must be a different file from the input dump"
  if [ -e "$out" ] && [ "$force" != "yes" ]; then
    die "output already exists: $out  (use --force to overwrite)"
  fi

  # --- identify the driver GUID we are injecting (for accurate detection) -
  local eg_hex
  eg_hex="$(ffs_guid_hex "$ffs" 2>/dev/null || true)"
  if ! printf '%s' "$eg_hex" | grep -qiE '^[0-9a-f]{32}$'; then
    eg_hex="$EG_GUID_HEX"
  fi
  if [ "$eg_hex" != "$EG_GUID_HEX" ]; then
    warn "the .ffs file GUID ($eg_hex) is not the known EnableGop GUID."
    warn "continuing, but confirm you picked the right driver .ffs."
  fi

  # --- pre-injection validation ------------------------------------------
  hr
  say "${C_BOLD}Pre-flight${C_RESET}"
  hr
  info "input : $in ($(human "$in_size"))"
  info "sha256: $(sha256_of "$in")"
  info "driver: EnableGop FFS GUID $eg_hex"

  looks_like_firmware "$in" \
    && ok "input has a UEFI firmware volume signature" \
    || warn "input has no _FVH signature — is this a real ROM dump?"

  if contains_bytes "$in" "$eg_hex"; then
    die "This driver GUID is ALREADY present in the dump.
     Injecting again would create duplicate instances (a known fault state).
     Start from a clean, un-modified dump."
  fi
  ok "input does not already contain this driver"

  # save a sidecar checksum of the original for your records
  local in_sha; in_sha="$(sha256_of "$in")"
  printf '%s  %s\n' "$in_sha" "$(basename "$in")" > "${in}.sha256" || true

  if [ "$yes" != "yes" ]; then
    printf '\n%sProceed to inject EnableGop into a copy?%s [y/N] ' "$C_BOLD" "$C_RESET"
    # `|| reply=""` keeps set -e from exiting on EOF (e.g. non-interactive stdin);
    # an empty/no answer then falls through to the abort below.
    read -r reply || reply=""
    case "$reply" in y|Y|yes|YES) ;; *) die "aborted by user" ;; esac
  fi

  # --- injection ----------------------------------------------------------
  hr
  say "${C_BOLD}Injecting${C_RESET}"
  hr
  info "$dxe \"$in\" \"$out\" \"$ffs\""
  if ! "$dxe" "$in" "$out" "$ffs"; then
    rm -f "$out"
    die "DXEInject failed — no output written."
  fi
  [ -f "$out" ] || die "DXEInject reported success but produced no output file."

  # --- post-injection validation -----------------------------------------
  hr
  say "${C_BOLD}Validating output${C_RESET}"
  hr
  local out_size; out_size="$(file_size "$out")"

  # 1) size invariant — the flash chip is fixed size; total must not change.
  if [ "$out_size" -ne "$in_size" ]; then
    warn "output is $out_size bytes; input is $in_size bytes"
    rm -f "$out" "${out}.sha256"
    die "FAILED size-invariant check. A cMP flash image must keep its exact
     total byte count. The bad output was deleted — nothing to flash."
  fi
  ok "size unchanged ($(human "$out_size")) — flash-size invariant holds"

  # 2) EnableGop must now be present (by its FFS GUID)
  if contains_bytes "$out" "$eg_hex"; then
    ok "EnableGop driver GUID is present in the output"
  else
    rm -f "$out" "${out}.sha256"
    die "FAILED — the EnableGop driver GUID was not found in the output.
     The bad output was deleted — nothing to flash."
  fi

  # 3) still a firmware image
  looks_like_firmware "$out" \
    && ok "output still carries a firmware volume signature" \
    || warn "output lost its _FVH signature — inspect before flashing"

  # 4) which regions changed?
  local d; d="$(report_diff "$in" "$out")"
  set -- $d
  if [ "${1:-}" = "IDENTICAL" ]; then
    rm -f "$out" "${out}.sha256"
    die "FAILED — output was byte-identical to input; nothing was injected.
     The output was deleted — nothing to flash."
  elif [ "${1:-}" = "CHANGED" ]; then
    local n="$2" first="$3" last="$4"
    local span=$(( last - first + 1 ))
    local pct; pct="$(awk -v s="$span" -v t="$in_size" 'BEGIN{printf "%.2f", (s*100.0)/t}')"
    ok "changed bytes: $n"
    printf '  changed region: %s0x%08X%s … %s0x%08X%s  (span %s, %s%% of ROM)\n' \
      "$C_BOLD" "$first" "$C_RESET" "$C_BOLD" "$last" "$C_RESET" "$(human "$span")" "$pct"
    # heuristic: warn if edits reach the tail, where NVRAM / serial data lives
    local tail_start=$(( in_size - 262144 ))   # last 256 KiB
    if [ "$last" -ge "$tail_start" ]; then
      warn "changes extend into the last 256 KiB of the ROM."
      warn "That region often holds NVRAM / serial / board data. Inspect the"
      warn "output in UEFITool and confirm your serial + NVRAM are intact"
      warn "before flashing."
    else
      ok "changes stay clear of the ROM tail (NVRAM/serial region looks untouched)"
    fi
  else
    warn "could not compute a diff region (cmp unavailable?) — inspect manually"
  fi

  printf '%s  %s\n' "$(sha256_of "$out")" "$(basename "$out")" > "${out}.sha256" || true

  # --- handoff ------------------------------------------------------------
  hr
  say "${C_BOLD}${C_GRN}Prepared ROM ready${C_RESET}"
  hr
  say "  output : ${C_BOLD}$out${C_RESET}"
  say "  sha256 : $(sha256_of "$out")"
  say ""
  say "  ${C_BOLD}Before you flash — checklist:${C_RESET}"
  say "   1. Keep your original dump ($in) untouched as a recovery image."
  say "   2. Have a hardware recovery path ready: CH341A + SOIC-8 clip, or a"
  say "      Matt card. If a flash goes bad, this is the only way back."
  say "   3. Open $out in UEFITool 0.25.1 and eyeball: EnableGop present once,"
  say "      NVRAM store intact, serial number unchanged."
  say "   4. Flash $out with Macschrauber's Rom Dump; let it verify the"
  say "      read-back before you reboot."
  say "   5. Reboot with the GPU on DisplayPort/HDMI — you should get a"
  say "      native boot screen."
  say ""
  say "  ${C_DIM}This tool did not touch your hardware. Nothing is flashed until"
  say "  you do it yourself in Rom Dump.${C_RESET}"
  hr
}

# ----------------------------------------------------------------------------
# fetch mode — pre-download dependencies into ./tools without injecting
# ----------------------------------------------------------------------------
do_fetch() {
  local ffs="$1" dxe_url="$2"
  [ -n "$ffs" ] || ffs="$TOOLS_DIR/EnableGop.ffs"
  fetch_enablegop_ffs "$OC_VERSION" "$ffs"
  if [ -n "$dxe_url" ]; then
    fetch_dxeinject "$dxe_url" "$TOOLS_DIR/DXEInject"
  else
    info "no --dxeinject-url given; skipping DXEInject."
    info "DXEInject is a dosdude1 tool, not part of OpenCore — supply it yourself"
    info "(drop it in $TOOLS_DIR/, or pass --dxeinject-url <https-url>)."
  fi
  ok "dependencies ready in $TOOLS_DIR"
}

# ----------------------------------------------------------------------------
# arg parsing
# ----------------------------------------------------------------------------
main() {
  local mode="" rom="" out="" ffs="./EnableGop.ffs" dxe="" force="no" yes="no"

  [ $# -gt 0 ] || { usage; exit 1; }

  # require an option to have a value argument. Guards the `shift 2` below:
  # without this, `shift 2` on a missing trailing value fails under `set -e`
  # and the script would exit silently before reaching the friendly checks.
  need_val() { [ "$2" -ge 2 ] || die "$1 requires a value  (try --help)"; }

  while [ $# -gt 0 ]; do
    case "$1" in
      --check)         need_val "$1" $#; mode="check";  rom="$2"; shift 2 ;;
      --inject)        need_val "$1" $#; mode="inject"; rom="$2"; shift 2 ;;
      --fetch)         mode="fetch"; shift ;;
      -o|--output)     need_val "$1" $#; out="$2"; shift 2 ;;
      -f|--ffs)        need_val "$1" $#; ffs="$2"; shift 2 ;;
      --dxeinject)     need_val "$1" $#; dxe="$2"; shift 2 ;;
      --dxeinject-url) need_val "$1" $#; DXEINJECT_URL="$2"; shift 2 ;;
      --oc-version)    need_val "$1" $#; OC_VERSION="$2"; shift 2 ;;
      --tools-dir)     need_val "$1" $#; TOOLS_DIR="$2"; shift 2 ;;
      --no-fetch)      NO_FETCH="yes"; shift ;;
      --force)         force="yes"; shift ;;
      -y|--yes)        yes="yes"; shift ;;
      -h|--help)       usage; exit 0 ;;
      --version)       echo "$PROG $VERSION"; exit 0 ;;
      *)               die "unknown argument: $1  (try --help)" ;;
    esac
  done

  [ -n "$mode" ] || die "choose a mode: --check, --inject, or --fetch (see --help)"

  case "$mode" in
    fetch)  # use the tools-dir default unless the user gave an explicit -f path
            local ffs_arg=""
            [ "$ffs" != "./EnableGop.ffs" ] && ffs_arg="$ffs"
            do_fetch "$ffs_arg" "$DXEINJECT_URL" ;;
    check)  [ -n "$rom" ] || die "no ROM file given"
            do_check "$rom" ;;
    inject) [ -n "$rom" ] || die "no ROM file given"
            [ -n "$out" ] || out="${rom%.rom}-enablegop.rom"
            do_inject "$rom" "$out" "$ffs" "$dxe" "$force" "$yes" ;;
  esac
}

main "$@"
