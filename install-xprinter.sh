#!/usr/bin/env bash
# install-xprinter.sh
# One-shot installer for Xprinter POS-58 / POS-80 USB thermal receipt printers
# on Ubuntu/Debian. Fixes the "prints raw code / garbage instead of receipt"
# problem caused by a missing or empty CUPS PPD.
#
# Usage:
#   chmod +x install-xprinter.sh
#   ./install-xprinter.sh                          # auto-detect USB, install
#   ./install-xprinter.sh --queue XP-80            # custom queue name
#   ./install-xprinter.sh --width 58               # 58mm printers (default 80)
#   ./install-xprinter.sh --bluetooth AA:BB:..:FF  # also set up Bluetooth queue
#   ./install-xprinter.sh --bt-channel 1           # SPP channel (default 1)
#   ./install-xprinter.sh --uninstall              # remove queue and PPD
#
# The Bluetooth printer must already be paired (use bluetoothctl). The script
# binds /dev/rfcomm0 to it, fixes CUPS backend permissions, patches the cupsd
# AppArmor profile to allow /dev/rfcomm*, and adds a parallel CUPS queue named
# <QUEUE>-BT.
#
# Tested on Ubuntu 22.04 / 24.04, Debian 12.
# Author: built for ERPNext / Frappe Print Format use cases.

set -euo pipefail

QUEUE="POS-80"
WIDTH_MM="80"
UNINSTALL=0
BT_MAC=""
BT_CHANNEL="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue)      QUEUE="$2"; shift 2 ;;
    --width)      WIDTH_MM="$2"; shift 2 ;;
    --bluetooth)  BT_MAC="$2"; shift 2 ;;
    --bt-channel) BT_CHANNEL="$2"; shift 2 ;;
    --uninstall)  UNINSTALL=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------- helpers ----------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; }

require_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null; then
      err "Run as root or install sudo."; exit 1
    fi
    SUDO="sudo"
  else
    SUDO=""
  fi
}

# ---------- uninstall path ----------
if [[ $UNINSTALL -eq 1 ]]; then
  require_sudo
  log "Removing queue '$QUEUE'..."
  $SUDO lpadmin -x "$QUEUE" 2>/dev/null || true
  $SUDO rm -f "/usr/share/ppd/xprinter-${WIDTH_MM}mm.ppd"
  ok "Removed."
  exit 0
fi

require_sudo

# ---------- 1. Install packages ----------
log "Installing CUPS + thermal-printer drivers..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
# foomatic-db and foomatic-db-compressed-ppds conflict; pick whichever is
# already installed and fall back to the compressed one.
FOOMATIC_PKG="foomatic-db-compressed-ppds"
if dpkg -l foomatic-db 2>/dev/null | grep -q '^ii'; then
  FOOMATIC_PKG="foomatic-db"
fi
$SUDO apt-get install -y -qq \
  cups cups-client cups-bsd cups-filters \
  printer-driver-all printer-driver-escpr \
  "$FOOMATIC_PKG" foomatic-db-engine \
  ghostscript poppler-utils \
  system-config-printer-common usbutils >/dev/null
ok "Packages installed."

# ---------- 2. Service + group ----------
$SUDO systemctl enable --now cups >/dev/null 2>&1 || true
if ! id -nG "$(logname 2>/dev/null || echo "$USER")" | grep -qw lpadmin; then
  log "Adding $(logname 2>/dev/null || echo "$USER") to lpadmin group..."
  $SUDO usermod -aG lpadmin "$(logname 2>/dev/null || echo "$USER")" || true
  warn "You may need to log out and back in for group change to take effect."
fi

# ---------- 3. Detect the printer ----------
log "Looking for Xprinter on USB..."
if ! lsusb | grep -qiE '1fc9:2016|0fe6:|0519:|154f:|0416:5011|xprinter|pos.?80|pos.?58'; then
  warn "No Xprinter-like USB device detected. Plug it in and power it on, then re-run."
  warn "Continuing anyway in case it is on a network/serial port."
fi

URI="$(lpinfo -v 2>/dev/null | awk '/^direct .*(POS|XP|Printer-80|Printer-58|Xprinter)/ {print $2; exit}')"
if [[ -z "${URI:-}" ]]; then
  # broader fallback: any usb:// printer
  URI="$(lpinfo -v 2>/dev/null | awk '/^direct usb:\/\// {print $2; exit}')"
fi
if [[ -z "${URI:-}" ]]; then
  err "Could not auto-detect a USB printer. Check 'lpinfo -v' manually."
  exit 2
fi
ok "Printer URI: $URI"

# ---------- 4. Compute paper size ----------
# Width in points (1mm = 2.83465pt). Length is set long; printer cuts at form-feed.
W_PT=$(awk -v w="$WIDTH_MM" 'BEGIN{printf "%.2f", w*2.83465}')
H_PT="841.89"   # ~297mm, plenty for any receipt
W_HW=$(awk -v w="$WIDTH_MM" 'BEGIN{printf "%d",  w*8}')   # 203 dpi -> 8 dots/mm
H_HW=2400

# ---------- 5. Write a working 80mm/58mm PPD ----------
PPD_PATH="/usr/share/ppd/xprinter-${WIDTH_MM}mm.ppd"
log "Writing PPD to $PPD_PATH..."
$SUDO tee "$PPD_PATH" >/dev/null <<PPD
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion:   "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName:    "XPRINT${WIDTH_MM}.PPD"
*Manufacturer:  "Xprinter"
*Product:       "(Xprinter ${WIDTH_MM}mm Thermal)"
*ModelName:     "Xprinter ${WIDTH_MM}mm Thermal"
*ShortNickName: "Xprinter ${WIDTH_MM}mm"
*NickName:      "Xprinter ${WIDTH_MM}mm Thermal Receipt (ESC/POS, raster)"
*PSVersion:     "(3010.000) 0"
*LanguageLevel: "3"
*ColorDevice:   False
*DefaultColorSpace: Gray
*FileSystem:    False
*Throughput:    "5"
*LandscapeOrientation: Plus90
*TTRasterizer: Type42
*cupsVersion:  2.4
*cupsModelNumber: 0
*cupsManualCopies: True
*cupsRasterVersion: "3"
*cupsBitsPerColor: 1
*cupsBitsPerPixel: 1
*cupsColorSpace:   3
*cupsCompression:  0
*cupsFilter:   "application/vnd.cups-raster 50 rastertoescpos"

*OpenUI *PageSize/Media Size: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: Custom.${WIDTH_MM}x297mm
*PageSize Custom.${WIDTH_MM}x297mm/${WIDTH_MM}mm Roll: "<</PageSize[${W_PT} ${H_PT}]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageSize

*OpenUI *PageRegion/Media Size: PickOne
*OrderDependency: 10 AnySetup *PageRegion
*DefaultPageRegion: Custom.${WIDTH_MM}x297mm
*PageRegion Custom.${WIDTH_MM}x297mm/${WIDTH_MM}mm Roll: "<</PageSize[${W_PT} ${H_PT}]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageRegion

*DefaultImageableArea: Custom.${WIDTH_MM}x297mm
*ImageableArea Custom.${WIDTH_MM}x297mm/${WIDTH_MM}mm Roll: "0 0 ${W_PT} ${H_PT}"
*DefaultPaperDimension: Custom.${WIDTH_MM}x297mm
*PaperDimension Custom.${WIDTH_MM}x297mm/${WIDTH_MM}mm Roll: "${W_PT} ${H_PT}"

*MaxMediaWidth:  "${W_PT}"
*MaxMediaHeight: "${H_PT}"
*HWMargins: 0 0 0 0
*CustomPageSize True: "pop pop pop <</PageSize[5 -2 roll]/ImagingBBox null>>setpagedevice"
*ParamCustomPageSize Width:        1 points 28.34 ${W_PT}
*ParamCustomPageSize Height:       2 points 28.34 ${H_PT}
*ParamCustomPageSize WidthOffset:  3 points 0 0
*ParamCustomPageSize HeightOffset: 4 points 0 0
*ParamCustomPageSize Orientation:  5 int 0 0

*OpenUI *Resolution/Resolution: PickOne
*OrderDependency: 20 AnySetup *Resolution
*DefaultResolution: 203dpi
*Resolution 203dpi/203 dpi: "<</HWResolution[203 203]>>setpagedevice"
*CloseUI: *Resolution

*DefaultFont: Courier
*Font AvantGarde-Book: Standard "(001.006S)" Standard ROM
*Font Courier: Standard "(002.004S)" Standard ROM
*Font Helvetica: Standard "(001.006S)" Standard ROM
*Font Times-Roman: Standard "(001.007S)" Standard ROM
PPD

# ---------- 6. Install rastertoescpos filter (Python) ----------
# CUPS will call /usr/lib/cups/filter/rastertoescpos. We ship a small,
# self-contained Python filter that converts CUPS raster -> ESC/POS GS v 0.
FILTER=/usr/lib/cups/filter/rastertoescpos
log "Installing CUPS filter at $FILTER..."
$SUDO tee "$FILTER" >/dev/null <<'PYFILTER'
#!/usr/bin/env python3
"""
rastertoescpos
Converts CUPS raster pages to ESC/POS GS v 0 raster bit-image commands.
Suitable for 58mm/80mm Xprinter / generic ESC/POS thermal receipt printers.
Args (CUPS): job-id user title copies options [filename]
"""
import sys, os, struct

# CUPS raster is on stdin (or the optional filename arg)
def open_input():
    if len(sys.argv) >= 7:
        return open(sys.argv[6], 'rb')
    return sys.stdin.buffer

def read_exact(f, n):
    buf = b''
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            return buf
        buf += chunk
    return buf

def main():
    f = open_input()
    out = sys.stdout.buffer

    sync = read_exact(f, 4)
    if sync not in (b'RaS2', b'RaS3', b'2SaR', b'3SaR'):
        sys.stderr.write("ERROR: not a CUPS raster stream (got %r)\n" % sync)
        sys.exit(1)
    little_endian = sync in (b'2SaR', b'3SaR')

    # v2/v3 page header is 1796 bytes; same layout for the fields we use.
    HDR_SIZE = 1796
    # Field offsets per cups/raster.h cups_page_header2_s:
    #   cupsWidth        @ 372 (uint32) - pixels per line
    #   cupsHeight       @ 376 (uint32) - lines
    #   cupsBitsPerColor @ 384 (uint32)
    #   cupsBitsPerPixel @ 388 (uint32)
    #   cupsBytesPerLine @ 392 (uint32)
    #   cupsColorSpace   @ 400 (uint32) - 0=W (0=black), 3=K (1=black)
    OFF_W, OFF_H, OFF_BPP, OFF_BPL, OFF_CS = 372, 376, 388, 392, 400

    # Initialize printer
    out.write(b'\x1b@')           # ESC @  reset
    out.write(b'\x1b\x33\x00')    # ESC 3 0  set line spacing 0

    endian = '<' if little_endian else '>'

    while True:
        hdr = read_exact(f, HDR_SIZE)
        if len(hdr) < HDR_SIZE:
            break

        width  = struct.unpack(endian+'I', hdr[OFF_W:OFF_W+4])[0]
        height = struct.unpack(endian+'I', hdr[OFF_H:OFF_H+4])[0]
        bpp    = struct.unpack(endian+'I', hdr[OFF_BPP:OFF_BPP+4])[0]
        bpl    = struct.unpack(endian+'I', hdr[OFF_BPL:OFF_BPL+4])[0]
        cs     = struct.unpack(endian+'I', hdr[OFF_CS:OFF_CS+4])[0]

        sys.stderr.write("DEBUG rastertoescpos: w=%d h=%d bpp=%d bpl=%d cs=%d\n"
                         % (width, height, bpp, bpl, cs))

        if bpp not in (1, 8):
            sys.stderr.write("ERROR: unsupported bpp=%d\n" % bpp)
            sys.exit(1)
        if width == 0 or height == 0 or bpl == 0:
            continue

        page = read_exact(f, bpl * height)

        # Normalize to 1bpp where bit=1 means "print dot" (fire pin / black).
        # CUPS color spaces:
        #   0 = W (gray, 0=black, 255=white)         -> invert
        #   3 = K (gray, 0=white, 255=black/ink)     -> as-is
        if bpp == 1:
            if cs == 0:           # W: 0=black, so invert bits
                page = bytes(b ^ 0xFF for b in page)
            # cs == 3 (K): bits already mean "ink" -> use as-is
        else:  # bpp == 8
            new_bpl = (width + 7) // 8
            buf = bytearray(new_bpl * height)
            invert = (cs == 0)
            for y in range(height):
                row_in  = page[y*bpl:(y+1)*bpl]
                row_out = bytearray(new_bpl)
                for x in range(width):
                    px = row_in[x]
                    dark = (px < 128) if invert else (px >= 128)
                    if dark:
                        row_out[x >> 3] |= 0x80 >> (x & 7)
                buf[y*new_bpl:(y+1)*new_bpl] = row_out
            page = bytes(buf)
            bpl  = new_bpl

        # Send in slices of <= 255 lines using GS v 0 (raster bit image)
        # GS v 0 m xL xH yL yH d1...
        MAX_LINES = 255
        sent = 0
        while sent < height:
            chunk = min(MAX_LINES, height - sent)
            xL =  bpl       & 0xff
            xH = (bpl >> 8) & 0xff
            yL =  chunk     & 0xff
            yH = (chunk >> 8) & 0xff
            out.write(b'\x1dv0\x00' + bytes([xL,xH,yL,yH]))
            out.write(page[sent*bpl:(sent+chunk)*bpl])
            sent += chunk

        # feed + cut at end of page
        out.write(b'\x1bd\x03')   # feed 3 lines
        out.write(b'\x1dV\x42\x00')  # GS V B 0 -- partial cut with feed

    # Final flush
    out.write(b'\x1bd\x02')
    out.flush()

if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        pass
PYFILTER
$SUDO chmod 755 "$FILTER"
$SUDO chown root:root "$FILTER"

# ---------- 7. Remove broken queue, add a fresh one ----------
if lpstat -p "$QUEUE" >/dev/null 2>&1; then
  log "Removing existing queue '$QUEUE' (it had an empty PPD)..."
  $SUDO lpadmin -x "$QUEUE" || true
fi

log "Adding queue '$QUEUE'..."
$SUDO lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD_PATH" \
  -o printer-is-shared=false \
  -o media=Custom.${WIDTH_MM}x297mm \
  -o Resolution=203dpi
$SUDO cupsenable "$QUEUE"
$SUDO cupsaccept "$QUEUE"
$SUDO lpadmin -d "$QUEUE"
ok "Queue '$QUEUE' installed and set as default."

# ---------- 8. Test ----------
log "Sending a small test page..."
TMP="$(mktemp --suffix=.txt)"
cat >"$TMP" <<EOF
========================================
       XPRINTER ${WIDTH_MM}mm TEST
========================================
Date : $(date '+%Y-%m-%d %H:%M:%S')
Host : $(hostname)
Queue: $QUEUE
URI  : $URI
----------------------------------------
If you can read this clearly, drivers
are working. Try printing a Print
Format from ERPNext now.
========================================

EOF
if lp -d "$QUEUE" "$TMP" >/dev/null 2>&1; then
  ok "Test job submitted. Check the printer."
else
  warn "Test job submission failed. Check 'lpstat -t' and /var/log/cups/error_log."
fi
rm -f "$TMP"

# ---------- 9. Optional Bluetooth setup ----------
if [[ -n "$BT_MAC" ]]; then
  log "Configuring Bluetooth printer at $BT_MAC (SPP channel $BT_CHANNEL)..."

  # 9a. Persistent rfcomm bind via systemd
  $SUDO tee /etc/systemd/system/rfcomm-printer.service >/dev/null <<EOF
[Unit]
Description=Bind Bluetooth thermal printer to /dev/rfcomm0
Requires=bluetooth.service
After=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/bin/rfcomm release 0
ExecStart=/usr/bin/rfcomm bind 0 ${BT_MAC} ${BT_CHANNEL}
ExecStartPost=/bin/sh -c "for i in 1 2 3 4 5; do [ -e /dev/rfcomm0 ] && break; sleep 0.2; done; chgrp lp /dev/rfcomm0; chmod 660 /dev/rfcomm0"
ExecStop=/usr/bin/rfcomm release 0

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable rfcomm-printer.service >/dev/null 2>&1
  $SUDO systemctl restart rfcomm-printer.service
  sleep 1

  # 9b. udev rule so re-bound device gets correct group
  $SUDO tee /etc/udev/rules.d/99-rfcomm-printer.rules >/dev/null <<EOF
KERNEL=="rfcomm0", GROUP="lp", MODE="0660"
EOF
  $SUDO udevadm control --reload-rules

  # 9c. Make CUPS run the serial backend as root (Ubuntu ships it 0744 which
  #     forces unprivileged execution and EACCES on /dev/rfcomm0)
  $SUDO chmod 0700 /usr/lib/cups/backend/serial

  # 9d. Allow cupsd's AppArmor profile to access /dev/rfcomm*
  if [[ -d /etc/apparmor.d/local ]] && [[ -f /etc/apparmor.d/usr.sbin.cupsd ]]; then
    $SUDO tee /etc/apparmor.d/local/usr.sbin.cupsd >/dev/null <<EOF
# Bluetooth thermal printers via SPP / rfcomm
/dev/rfcomm[0-9]* rw,
EOF
    $SUDO apparmor_parser -r /etc/apparmor.d/usr.sbin.cupsd 2>/dev/null || \
      warn "apparmor_parser failed; reload manually if BT print returns EACCES."
    $SUDO systemctl restart cups
  fi

  # 9e. Add the BT CUPS queue using the same PPD/filter
  BT_QUEUE="${QUEUE}-BT"
  if lpstat -p "$BT_QUEUE" >/dev/null 2>&1; then
    $SUDO lpadmin -x "$BT_QUEUE" || true
  fi
  $SUDO lpadmin -p "$BT_QUEUE" -E \
    -v "serial:/dev/rfcomm0?baud=9600" \
    -P "$PPD_PATH" \
    -o printer-is-shared=false \
    -o "media=Custom.${WIDTH_MM}x297mm" \
    -o Resolution=203dpi
  $SUDO cupsenable "$BT_QUEUE"
  $SUDO cupsaccept "$BT_QUEUE"
  ok "Bluetooth queue '$BT_QUEUE' installed."
fi

cat <<MSG

---------------------------------------------------------------
Done.

Useful commands:
  lpstat -t                                 # all queues + jobs
  lpstat -p $QUEUE                          # this queue's status
  cancel -a $QUEUE                          # clear stuck jobs
  sudo cupsenable $QUEUE                    # un-pause after a fault
  tail -n 50 /var/log/cups/error_log        # diagnostics

Re-run with --width 58 if your printer is the 58mm model.
Re-run with --uninstall to remove the queue.

In ERPNext / Frappe:
  - Printing Settings -> "Use Raw Print" should be OFF.
  - Print Format -> set page width to ${WIDTH_MM}mm,
    page height: auto / 297mm.
  - For best results use a "POS Receipt" style format.
---------------------------------------------------------------
MSG
