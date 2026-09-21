# GopForge

A guided shell tool that **injects the EnableGop DXE driver into a Mac Pro 4,1/5,1
boot ROM and validates the result** — producing a ready-to-flash `.rom`.

It automates the fiddly, error-prone middle of the process. It does **not** dump
your ROM and does **not** flash your hardware — those are done with
[Macschrauber's Rom Dump](https://github.com/Macschrauber/Macschrauber-s-Rom-Dump),
which already does them safely. Re-implementing a SPI flasher would only be a
riskier copy of a solved problem, so this tool deliberately stops at "here is a
validated ROM, now flash it in Rom Dump."

The point of a native EnableGop boot ROM is a real, native boot screen /
Startup Manager with a modern UEFI GPU (RX 500/Vega/Navi, R9 Fury, etc.) — no GPU
flash and no OpenCore required.

---

## ⚠️ Read this first

Flashing the boot ROM of a Mac Pro 4,1/5,1 can **brick the machine**. The normal
dump/flash is done **in-system in software** with Macschrauber's Rom Dump — no
desoldering — which is how EnableGop is installed. But if a flash goes wrong the
machine may no longer boot to run that software, and then the only way back is
**hardware**: reprogramming the SPI chip with a **CH341A + SOIC-8 clip** (the chip
is soldered, so in practice this usually means desoldering it) or a **"Matt
card."** Do not begin unless you have that recovery path and an **untouched
backup** of your original dump.

This tool is provided **as-is, with no warranty** (see [LICENSE](LICENSE)). It has
**not** been validated against every possible ROM revision — it validates *your*
file with checks and asks you to inspect the result, but it cannot guarantee a
safe flash. You flash at your own risk.

What this tool will *not* let you do accidentally:

- It never modifies your input dump (always writes a new file).
- It refuses to inject into a dump that already contains EnableGop (which would
  create duplicate instances — a known fault state).
- It fails loudly, and tells you **not to flash**, if the output changes the
  ROM's total size, doesn't actually contain EnableGop, or comes back identical
  to the input.

---

## The full picture (where this fits)

```
   ┌─────────┐     ┌──────────────────────────┐     ┌──────────┐
   │  DUMP    │ ──▶ │  INJECT + VALIDATE        │ ──▶ │  FLASH   │
   │ Rom Dump │     │  gopforge.sh (this)       │     │ Rom Dump │
   └─────────┘     └──────────────────────────┘     └──────────┘
     hardware            this repo                      hardware
```

1. **Dump** your boot ROM with Rom Dump → `mymac.rom`
2. **Prepare** it with this tool → `mymac-enablegop.rom`
3. **Inspect** it in UEFITool 0.25.1 (serial + NVRAM intact, EnableGop present once)
4. **Flash** `mymac-enablegop.rom` with Rom Dump, let it verify
5. **Reboot** with the GPU on DisplayPort/HDMI → native boot screen

---

## Prerequisites

| Thing | How the script gets it |
| --- | --- |
| **`EnableGop.ffs`** | **Auto-fetched** over HTTPS from the official OpenCorePkg release (`Utilities/EnableGop/EnableGop_<ver>.ffs`). It picks the standard, newest, non-dev `.ffs` — not the `EnableGopDirect` variant. Override the version with `--oc-version`, or supply your own with `-f`. |
| **`DXEInject`** | **Auto-fetched** over HTTPS from `dosdude1.com/apps/DXEInject.zip` by default. It's a **dosdude1** tool, *not* part of OpenCore, and unsigned — so its SHA-256 is pinned on first fetch (trust-on-first-use) and a later change is refused. To use your own copy instead, drop it in `./tools/`, pass `--dxeinject <path>`, or override `--dxeinject-url`. |
| **Macschrauber's Rom Dump** | For the actual dump and flash. Not called by this script — you run it yourself. |

`bash`, `perl`, `cmp`, `awk`, plus `curl`/`wget` and `unzip` for fetching — all
present by default on macOS and virtually every Linux.

Grab the dependencies ahead of time if you like:

```bash
./gopforge.sh --fetch                                 # EnableGop.ffs + DXEInject
./gopforge.sh --fetch --dxeinject-url https://…/DXEInject   # override the source
```

> Manual alternative to DXEInject: insert the `.ffs` into the DXE volume by hand
> with **UEFITool 0.25.1** (newer UEFITool builds are read-only and can't write).
> Then run `--check` on the result to confirm the driver landed.

### How it knows EnableGop is present

The driver stores no readable "EnableGop" string, so the tool detects it by its
**FFS GUID** (`3FBA58B1-F8C0-41BC-ACD8-253043A3A17F`, stable across versions and
the Direct variant). On `--inject` it reads the GUID from the exact `.ffs` you're
injecting and confirms *that* GUID appears in the output — so validation tracks
the real driver, not a guessed string.

---

## Usage

Make it executable once:

```bash
chmod +x gopforge.sh
```

**Inspect a ROM** (do this before *and* after injecting):

```bash
./gopforge.sh --check mymac.rom
```

**Inject EnableGop and validate** (EnableGop.ffs is fetched automatically if absent):

```bash
./gopforge.sh --inject mymac.rom --dxeinject ./tools/DXEInject
# → fetches EnableGop.ffs if needed, writes mymac-enablegop.rom + a .sha256
#   sidecar, then runs all checks
```

Handy options:

```
-o, --output <file>      output path (default: <dump>-enablegop.rom)
-f, --ffs <file>         path to EnableGop.ffs (auto-fetched if absent)
    --direct             use the EnableGopDirect variant (see troubleshooting)
    --dxeinject <p>      path to DXEInject
    --dxeinject-url <u>  HTTPS URL to auto-fetch DXEInject (SHA-256 pinned)
    --oc-version <v>     OpenCore release to pull EnableGop.ffs from
    --tools-dir <dir>    where fetched tools go (default: ./tools)
    --no-fetch           never download anything; require local files
    --force              overwrite an existing output
-y, --yes                non-interactive (skip the confirm prompt)
```

### What the validation checks

- **Firmware sanity** — the input carries a UEFI firmware volume signature (`_FVH`).
- **Not already patched** — aborts if EnableGop is already inside the dump.
- **Size invariant** — the output is byte-for-byte the same *total size* as the
  input (a fixed-size SPI image must not grow or shrink). A mismatch is a hard fail.
- **EnableGop present** — the driver is actually detectable in the output.
- **Changed-region report** — prints the byte range that changed and warns if
  edits reach the last 256 KiB of the ROM, where NVRAM / serial / board data
  typically lives, so you can confirm those weren't disturbed.
- **Checksums** — writes `.sha256` sidecars for both the original and the output.

None of these can *prove* a good flash — always open the result in UEFITool and
eyeball it — but they catch the common ways an injection goes wrong before you
ever write to the chip.

> **ROM size:** a **MacPro4,1/5,1 BootROM is exactly 4 MiB** (a 32 Mbit SPI part
> such as the `SST25VF032B` — every factory 4,1/5,1 uses a 4 MiB chip). `--check`
> flags anything else, and `--inject` **refuses** a non-4 MiB image (override with
> `--allow-size`). A 2 MiB image is a pre-4,1 Mac Pro (3,1 and older use a
> different, non-SPI firmware that is not EnableGop-compatible) or a partial dump,
> and EnableGop cannot be added to it.

---

## Troubleshooting: no boot screen after flashing

A clean, validated flash can still give **no pre-boot screen** — because
main-firmware EnableGop only *supplies OpenCore's GOP plumbing*; the **GPU itself
must be able to render before OpenCore**. Per the official
[EnableGop notes](https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/EnableGop),
work through this:

1. **Test with `BootKicker.efi`** (from the OpenCore release). Launch it and see
   whether the **native Apple boot picker** appears.
   - **Picker shows** → the card *can* do pre-boot graphics. If the standard
     build gave nothing, re-inject with **`--direct`** (the `EnableGopDirect`
     variant, for GPUs that need `DirectGopRendering`), then re-flash.
   - **Nothing shows** → the card has no usable GOP in its own option ROM. Main
     firmware alone can't fix this (next point).
2. **Cards that rely on OCLP "Enable AMD GOP"** (many ex-mining / older AMD cards,
   including some **R9 Fury / Fiji**) have **no GOP in their VBIOS**. To get
   graphics *before* OpenCore you must **burn a GOP driver into the GPU's own
   firmware** with EnableGop's `vBiosInsert.sh` + `amdvbflash` — a separate,
   riskier procedure from flashing the boot ROM. See the OpenCore EnableGop
   README and the MacRumors *pre-OpenCore GOP* thread.
3. **Check the display connection** — the boot screen appears on the port the GOP
   initializes; try **DisplayPort**, a single monitor, connected before power-on.
4. **Confirm variant vs config** — use `EnableGopDirect` (`--direct`) when your
   OpenCore `UEFI/Output/DirectGopRendering` is `true`; the standard build
   otherwise (it renders faster).

Both variants share the same FFS GUID, so GopForge validates either one. Start
from a **clean, un-injected dump** each time you switch variants (the tool
refuses to inject into a ROM that already contains EnableGop).

> **"Signal comes on at the chime, but the screen stays black until OpenCore."**
> This is **success, not failure** — EnableGop has brought the GPU's GOP up early
> (the monitor now syncs at power-on). On a non-native GPU, a *silent* boot won't
> necessarily draw the gray Apple logo, but the real UIs will: **hold ⌥ (Option)
> at power-on and you should get the native boot picker** before OpenCore. Target
> Disk Mode (**T**), the firmware-password prompt, and the macOS progress screen
> also render. The ALT picker is the deliverable.
>
> *Confirmed working:* AMD **Vega 64** on a MacPro5,1 (4 MiB BootROM, 144.0.0.0.0)
> with the **`--direct`** variant — native ⌥ boot picker on DisplayPort.

---

## Credits

- **EnableGop** — Mike Beaton, distributed with
  [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg)
  (`Utilities/EnableGop/` in the release zip; `Staging/EnableGop` in source).
- **Rom Dump / cMP flashing** —
  [Macschrauber](https://github.com/Macschrauber/Macschrauber-s-Rom-Dump).
- Community documentation: the MacRumors *EnableGop* and *rebuild bootrom with
  template files* threads.

This project bundles none of their code; it orchestrates the tools you download
yourself.

## License

MIT — see [LICENSE](LICENSE). No warranty. You flash at your own risk.
