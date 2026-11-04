#!/usr/bin/env bash
# Build HP_Prime_Connectivity_Kit-<version>-x86_64.AppImage
#
# What goes in:
#   * a portable Wine build (Kron4ek/Wine-Builds, "amd64-wow64" = no 32-bit host libs needed)
#   * the HP Connectivity Kit MSI + VC++ runtime, unpacked from HP's official installer
#   * AppRun launcher, udev rule, desktop file, icon
#
# Build dependencies (Debian/Ubuntu):
#   sudo apt install curl xz-utils cabextract msitools p7zip-full python3 file
#
# Usage:
#   ./build.sh                       download everything and build
#   ./build.sh --ck-installer FILE   use an HP Connectivity Kit installer you already have
#   ./build.sh --help
set -euo pipefail

# ---------------------------------------------------------------- pinned inputs (override via env)
WINE_VERSION="${WINE_VERSION:-11.0}"
WINE_URL="${WINE_URL:-https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/wine-${WINE_VERSION}-amd64-wow64.tar.xz}"
WINE_SHA256="${WINE_SHA256-39574efa1132c3ca0d5c77dd2eddbe4a49cca0d6cc2c290ff4924493a1c40314}"

# HP Connectivity Kit 2.4.2 (2026-09-09), 64-bit, official HP file mirrored on hpcalc.org.
CK_URL="${CK_URL:-https://www.hpcalc.org/prime/pc/HP_Prime_Connectivity_Kit_x64_20260909.exe}"
CK_SHA256="${CK_SHA256-ebd00e76de63dc00c31b19a93720a0459c8edfdcd80b00df6dba7e9e12a649f9}"

APPIMAGETOOL_URL="${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
CACHE="$BUILD/cache"
APPDIR="$BUILD/AppDir"
CK_INSTALLER=""

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ck-installer) CK_INSTALLER="$(readlink -f "$2")"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
[ "$(uname -m)" = x86_64 ] || die "Only x86_64 is supported (the Connectivity Kit is x86 Windows software)."
missing=()
for t in curl tar xz cabextract msiinfo 7z python3 sha256sum; do command -v "$t" >/dev/null || missing+=("$t"); done
if [ ${#missing[@]} -gt 0 ]; then
    die "Missing tools: ${missing[*]}
  Debian/Ubuntu: sudo apt install curl xz-utils cabextract msitools p7zip-full python3"
fi

fetch() {  # fetch URL DEST [SHA256]
    local url="$1" dest="$2" sum="${3:-}"
    if [ ! -s "$dest" ]; then
        say "Downloading $(basename "$dest")"
        curl -fL --retry 3 --progress-bar -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    if [ -n "$sum" ]; then
        echo "$sum  $dest" | sha256sum -c --quiet - || { rm -f "$dest"; die "Checksum mismatch for $dest"; }
    fi
}

mkdir -p "$CACHE"
rm -rf "$APPDIR" "$BUILD/ck"
mkdir -p "$APPDIR"/{opt/wine,payload} "$BUILD/ck"

# ---------------------------------------------------------------- inputs
fetch "$WINE_URL" "$CACHE/$(basename "$WINE_URL")" "$WINE_SHA256"
fetch "$APPIMAGETOOL_URL" "$CACHE/appimagetool-x86_64.AppImage"
chmod +x "$CACHE/appimagetool-x86_64.AppImage"
if [ -z "$CK_INSTALLER" ]; then
    CK_INSTALLER="$CACHE/$(basename "$CK_URL")"
    fetch "$CK_URL" "$CK_INSTALLER" "$CK_SHA256"
fi
[ -f "$CK_INSTALLER" ] || die "CK installer not found: $CK_INSTALLER"

# ---------------------------------------------------------------- Wine
say "Unpacking Wine $WINE_VERSION"
tar -xJf "$CACHE/$(basename "$WINE_URL")" -C "$APPDIR/opt/wine" --strip-components=1
# Drop the development bits (headers, import libs, compilers): ~170 MB we don't need at runtime.
rm -rf "$APPDIR/opt/wine/include"
find "$APPDIR/opt/wine" -name '*.a' -delete
rm -f "$APPDIR/opt/wine/bin/"{function_grep.pl,widl,winebuild,winecpp,wineg++,winegcc,winemaker,wmc,wrc,winedump}
# Wine's IUISettings2::get_TextScaleFactor is an E_NOTIMPL stub, which makes the CK abort at startup.
python3 -I "$ROOT/patch-windows-ui.py" "$APPDIR/opt/wine/lib/wine/x86_64-windows/windows.ui.dll" \
    || die "Could not patch windows.ui.dll (different Wine version?). The CK would crash on startup."

# ---------------------------------------------------------------- Connectivity Kit payload
say "Unpacking $(basename "$CK_INSTALLER")"
case "${CK_INSTALLER,,}" in
    *.msi)
        cp "$CK_INSTALLER" "$APPDIR/payload/ConnectivityKit.msi"
        ;;
    *.exe)
        # HP ships a WiX "Burn" bundle; its payloads sit in a cabinet attached to the exe.
        cabextract -q -d "$BUILD/ck" "$CK_INSTALLER" || die "Could not unpack the installer (not a WiX bundle?)"
        # File "0" is the bundle manifest: map payload names (VC_redist.x64.exe, ConnectivityKit.msi) to cab entries.
        python3 -I - "$BUILD/ck" "$APPDIR/payload" <<'PY'
import sys, os, shutil, xml.dom.minidom as m
src, dst = sys.argv[1], sys.argv[2]
d = m.parse(os.path.join(src, "0"))
want = {"vc_redist.x64.exe": "VC_redist.x64.exe", "connectivitykit.msi": "ConnectivityKit.msi"}
found = set()
for p in d.getElementsByTagName("Payload"):
    name = p.getAttribute("FilePath").split("\\")[-1].lower()
    if name in want:
        shutil.copy(os.path.join(src, p.getAttribute("SourcePath")), os.path.join(dst, want[name]))
        found.add(name)
missing = set(want) - found
if "connectivitykit.msi" in missing:
    sys.exit("ConnectivityKit.msi not found in bundle manifest")
if missing:
    print("warning: not in bundle:", ", ".join(missing))
PY
        ;;
    *) die "Unsupported installer type: $CK_INSTALLER" ;;
esac

MSI="$APPDIR/payload/ConnectivityKit.msi"
CK_VERSION="$(msiinfo export "$MSI" Property | awk -F'\t' '$1=="ProductVersion"{print $2}' | tr -d '\r')"
[ -n "$CK_VERSION" ] || die "Could not read the CK version from the MSI"
echo "$CK_VERSION" >"$APPDIR/payload/VERSION"
say "Connectivity Kit version: $CK_VERSION"

# Icon: the MSI carries the exe icon; its 256x256 PNG is the first ICON resource.
mkdir -p "$BUILD/ck/icon"
if msiinfo extract "$MSI" Icon.PRODUCT_ICON.exe >"$BUILD/ck/icon/icon.exe" 2>/dev/null \
   && 7z e -y -o"$BUILD/ck/icon" "$BUILD/ck/icon/icon.exe" '.rsrc/ICON/*' >/dev/null 2>&1; then
    best=""; bestsize=0
    for f in "$BUILD/ck/icon"/*; do
        if file "$f" | grep -q 'PNG image' && [ "$(stat -c %s "$f")" -gt "$bestsize" ]; then
            best="$f"; bestsize="$(stat -c %s "$f")"
        fi
    done
fi
if [ -n "${best:-}" ]; then
    cp "$best" "$APPDIR/hp-prime-ck.png"
else
    say "Icon extraction failed, using a plain placeholder icon"
    python3 -I - "$APPDIR/hp-prime-ck.png" <<'PY'
import sys, zlib, struct
w = h = 64
rows = b"".join(b"\0" + bytes([30, 90, 160, 255]) * w for _ in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
PY
fi

# ---------------------------------------------------------------- AppDir
say "Assembling AppDir"
cp "$ROOT/appdir/AppRun" "$ROOT/appdir/hp-prime-ck.desktop" "$ROOT/appdir/70-hp-prime.rules" "$APPDIR/"
chmod +x "$APPDIR/AppRun"
ln -sf hp-prime-ck.png "$APPDIR/.DirIcon"
du -sh "$APPDIR" | awk '{print "    AppDir size: "$1}'

# ---------------------------------------------------------------- AppImage
OUT="$ROOT/HP_Prime_Connectivity_Kit-${CK_VERSION}-x86_64.AppImage"
say "Building $(basename "$OUT")"
# Extract-and-run so the build also works where FUSE isn't available (containers, CI).
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$CACHE/appimagetool-x86_64.AppImage" \
    --no-appstream "$APPDIR" "$OUT"
chmod +x "$OUT"
say "Done: $OUT ($(du -h "$OUT" | cut -f1))"
cat <<EOF

Next steps:
  1. Run it:                     $OUT
     (first start installs the Connectivity Kit into ~/.local/share/hp-prime-ck)
  2. Allow USB access (once):    $OUT --setup-usb
  3. Optional menu entry:        $OUT --install-desktop
EOF
