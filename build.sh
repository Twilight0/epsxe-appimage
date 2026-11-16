#!/usr/bin/env bash
# Build a self-contained ePSXe 2.0.5 AppImage for x86_64.
#
# ePSXe 2.0.5 is a closed-source 64-bit Linux binary from 2010 that expects
# a pre-2019 runtime:
#
#   * libncurses.so.5 / libtinfo.so.5 with the NCURSES_TINFO_5.0.19991023
#     symbol version node,
#   * libcrypto.so.1.0.0 / libssl.so.1.0.0 (OpenSSL 1.0),
#   * libcurl.so.4 exporting CURL_OPENSSL_3 (not the CURL_OPENSSL_4 that
#     current libcurl provides),
#   * SDL 1.2.
#
# None of those exist on a current distro, so we bundle them.
#
# The upstream PSEmu Pro plugin set (Pete Bernert's PEOpS SoftX / MesaGL /
# OSS, Pete's XGL2, and padJoy) is published as 32-bit i386 binaries only and
# cannot be loaded by the 64-bit binary, so the 64-bit plugins are built from
# the PCSX-Reloaded 1.9.95 sources (the same source the Arch AUR 'epsxe'
# package uses).
#
# Usage: build.sh <output-dir>
#   Env: KEEP_WORK=1   keep the temporary work directory for inspection
set -euo pipefail

OUT_DIR="${1:?usage: build.sh <output-dir>}"
mkdir -p "$OUT_DIR"

WORK="$(mktemp -d)"
if [ "${KEEP_WORK:-0}" = "1" ]; then
  trap 'echo "work dir kept: $WORK"' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

APPDIR="$WORK/ePSXe.AppDir"
EPSXE_VER=2.0.5
PLGN_VER=1.9.95
UBUNTU_POOL="http://archive.ubuntu.com/ubuntu/pool"

mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/plugins" \
         "$APPDIR/usr/config" "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
         "$APPDIR/usr/share/applications" "$APPDIR/usr/share/doc/epsxe"

# Download cache: re-runs reuse already fetched archives.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/epsxe-appimage-build"
mkdir -p "$CACHE"

# fetch <url> <dest> — cached, with retries on transient network errors.
fetch() {
  local url="$1" dest="$2" name cached
  name="$(printf '%s' "$url" | md5sum | cut -d' ' -f1)"
  cached="$CACHE/$name"
  if [ ! -s "$cached" ]; then
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$cached" "$url"
  fi
  cp "$cached" "$dest"
}

log() { printf '\n=== %s\n' "$*"; }

# ---------------------------------------------------------------- ePSXe ---
log "Fetching ePSXe ${EPSXE_VER} (official x86_64 build)"
fetch "https://www.epsxe.com/files/ePSXe${EPSXE_VER//./}linux_x64.zip" "$WORK/epsxe.zip"
python3 - "$WORK/epsxe.zip" "$APPDIR" <<'PY'
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1])
out = sys.argv[2]
for name in z.namelist():
    if name.endswith('epsxe_x64'):
        with z.open(name) as s, open(os.path.join(out, 'usr/bin/epsxe_x64'), 'wb') as d:
            d.write(s.read())
        os.chmod(os.path.join(out, 'usr/bin/epsxe_x64'), 0o755)
    elif name.startswith('docs/') and name.endswith('.txt'):
        z.extract(name, out)
PY
mv "$APPDIR/docs/"*.txt "$APPDIR/usr/share/doc/epsxe/" 2>/dev/null || true
rm -rf "$APPDIR/docs"

# --------------------------------------------------------------- shaders ---
log "Fetching shaders"
if fetch "https://www.epsxe.com/files/shaders.zip" "$WORK/shaders.zip"; then
  mkdir -p "$WORK/shaders" && unzip -q -o "$WORK/shaders.zip" -d "$WORK/shaders"
  mkdir -p "$APPDIR/usr/shaders"
  if [ -d "$WORK/shaders/shaders" ]; then
    cp -r "$WORK/shaders/shaders/." "$APPDIR/usr/shaders/"
  else
    cp -r "$WORK/shaders/." "$APPDIR/usr/shaders/"
  fi
fi

# --------------------------------------------------------- runtime closure --
# The modern desktop stack (GTK3, SDL, GL, X11, ALSA) comes from the runtime
# that the upstream ePSXe AppImage already bundles for exactly this binary
# (Ubuntu 18.04). Two things in it are wrong for a current distro and are
# replaced below:
#
#   * its libncurses/libtinfo .so.5 carry no NCURSES_TINFO_5.0.19991023
#     version node, which the binary requires,
#   * its libssl.so.1.1 and libunistring.so.2 (needed by its libssh2,
#     libldap_r and libpsl) were never bundled at all.
log "Collecting the runtime library set"

fetch "https://github.com/amirzaim/epsxe-appimage/releases/download/epsxe/ePSXe_PS1_Emulator-x86_64.AppImage" \
      "$WORK/upstream.AppImage"
mkdir -p "$WORK/upstream"
(cd "$WORK/upstream" && chmod +x "$WORK/upstream.AppImage" && "$WORK/upstream.AppImage" --appimage-extract >/dev/null 2>&1) || true

UP_LIB="$WORK/upstream/squashfs-root/usr/lib/x86_64-linux-gnu"
if [ -d "$UP_LIB" ]; then
  for so in "$UP_LIB"/*.so*; do
    [ -e "$so" ] || continue
    base="$(basename "$so")"
    case "$base" in
      libncurses.so.5*|libtinfo.so.5*|libtic.so.5*|libform.so.5*|libmenu.so.5*|libpanel.so.5*) continue ;;
      # Wayland: the upstream bundle's 18.04 libwayland-client is older than
      # the host's libwayland-cursor, which then fails on wl_proxy_marshal_flags.
      # Mixing the two breaks; take the host's consistent set instead.
      libwayland-*) continue ;;
      libxkbcommon.so.0) continue ;;
    esac
    cp -aL "$so" "$APPDIR/usr/lib/" 2>/dev/null || true
  done
fi

log "Fetching legacy runtime libraries"
mkdir -p "$WORK/debs"
for u in \
  "main/n/ncurses/libncurses5_6.0+20160213-1ubuntu1_amd64.deb" \
  "main/n/ncurses/libtinfo5_6.0+20160213-1ubuntu1_amd64.deb" \
  "main/o/openssl/libssl1.0.0_1.0.2g-1ubuntu4.20_amd64.deb" \
  "main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb" \
  "main/libu/libunistring/libunistring2_0.9.10-2_amd64.deb" ; do
  fetch "$UBUNTU_POOL/$u" "$WORK/debs/$(basename "$u")"
done

mkdir -p "$WORK/debex"
for d in "$WORK"/debs/*.deb; do
  ar p "$d" data.tar.xz | tar -xJ -C "$WORK/debex"
done

for dir in "$WORK/debex/lib/x86_64-linux-gnu" "$WORK/debex/usr/lib/x86_64-linux-gnu"; do
  [ -d "$dir" ] || continue
  for so in "$dir"/libncurses.so.5* "$dir"/libtinfo.so.5* "$dir"/libtic.so.5* \
            "$dir"/libssl.so.1.0.0* "$dir"/libcrypto.so.1.0.0* \
            "$dir"/libssl.so.1.1* "$dir"/libcrypto.so.1.1* \
            "$dir"/libunistring.so.2*; do
    [ -e "$so" ] || continue
    cp -aL "$so" "$APPDIR/usr/lib/" 2>/dev/null || true
  done
done

echo "  bundled $(find "$APPDIR/usr/lib" -type f | wc -l) libraries"

# ---------------------------------------------------------- 64-bit plugins --
log "Building 64-bit plugins from PCSX-Reloaded ${PLGN_VER}"
git clone -q --depth 1 --branch "$PLGN_VER" \
  https://github.com/frealgagu/PCSX-Reloaded.git "$WORK/pcsxr"
cd "$WORK/pcsxr/pcsxr"

# Build only the Linux-relevant plugins. dfxvideo is a DirectX plugin and
# bladesio1 is the Windows SIO1 interface: neither is usable here, and both
# fail to compile against a modern toolchain.
cat > Makefile.am <<'EOF'
SUBDIRS = plugins/dfinput
SUBDIRS += plugins/dfsound
SUBDIRS += plugins/dfcdrom
SUBDIRS += plugins/dfnet
SUBDIRS += $(PEOPSXGL)

DIST_SUBDIRS = $(SUBDIRS) plugins/bladesio1 plugins/peopsxgl

EXTRA_DIST = AUTHORS COPYING INSTALL NEWS README ChangeLog ChangeLog.df strip_fPIC.sh
EOF

python3 - <<'PY'
p = 'configure.ac'
s = open(p).read()
for blk in ('plugins/dfxvideo/Makefile', 'plugins/bladesio1/Makefile'):
    s = s.replace(blk + '\n', '')
open(p, 'w').write(s)
PY

mkdir -p include

# Toolchain fixes for modern GCC.
sed -ri 's|(#include "pad.h")|\1\n#include <sys/wait.h>|' plugins/dfinput/pad.c
sed -ri 's|(#include "stdafx.h")|\1\n#include <sys/wait.h>|' plugins/dfsound/cfg.c
sed -ri 's|(#include "cdr.h")|\1\n#include <sys/wait.h>|' plugins/dfcdrom/cdr.c
sed -ri 's|(#include "stdafx.h")|\1\n#include <sys/wait.h>|' plugins/peopsxgl/gpu.c
sed -ri 's|\*disp=\(unsigned long \*\)display;|*disp=(unsigned long)display;|' plugins/peopsxgl/gpu.c
# Old-style (unprototyped) declaration clashes with the real definition.
sed -i 's|^int OpenCdHandle();|int OpenCdHandle(const char *dev);|' plugins/dfcdrom/cdr.h
# ePSXe looks in ~/.epsxe, PCSX-Reloaded in ~/.pcsxr.
sed -i 's|\.pcsxr|.epsxe|g' gui/Linux.h
sed -i 's|/games/psemu/||g' plugins/peopsxgl/Makefile.am
sed -i 's|/psemu/||g' plugins/peopsxgl/Makefile.am
# The plugin config GUI lives next to the plugin itself.
sed -i 's|%s/\.epsxe/plugins/cfg/cfgpeopsxgl|%s/.epsxe/plugins/cfgpeopsxgl|' \
  plugins/peopsxgl/gpu.c

export CC=gcc CXX=g++
export CFLAGS="-fcommon -O2 -Wno-error"
export CXXFLAGS="-O2 -Wno-error"

autoreconf -fi >/dev/null 2>&1
intltoolize --force >/dev/null 2>&1

./configure \
  --prefix=/opt/epsxe \
  --enable-opengl \
  --disable-libcdio \
  --libdir="$APPDIR/usr/plugins" \
  --datadir="$APPDIR/usr/config" \
  --bindir="$APPDIR/usr/plugins" \
  --datarootdir="$APPDIR/usr/config" >/dev/null

make -j"$(nproc)" >"$WORK/make.log" 2>&1 || {
  echo "plugin build failed:"; grep -E "error:" "$WORK/make.log" | head -20; tail -20 "$WORK/make.log"; exit 1; }

# Plugins are linked into the build tree (libtool .libs/), not installed.
for pdir in "$WORK/pcsxr/pcsxr/plugins"/*/; do
  pname="$(basename "$pdir")"
  [ -d "$pdir/.libs" ] || continue
  for so in "$pdir/.libs"/*.so; do
    [ -e "$so" ] || continue
    cp -a "$so" "$APPDIR/usr/plugins/"
  done
  # Config helper (e.g. cfgpeopsxgl, cfgDFInput) goes next to the plugin.
  for cfg in "$pdir"/cfg*; do
    [ -f "$cfg" ] && [ -x "$cfg" ] || continue
    case "$cfg" in *.c|*.h|*.la|*.o) continue ;; esac
    cp -a "$cfg" "$APPDIR/usr/plugins/"
  done
  # .ui definitions used by the config GUIs.
  if [ -d "$pdir/gpucfg" ]; then
    cp -a "$pdir/gpucfg/." "$APPDIR/usr/config/" 2>/dev/null || true
  fi
done
find "$APPDIR/usr/plugins" -name '*.la' -delete
find "$APPDIR/usr/plugins" -type d -empty -delete
find "$WORK/pcsxr" -name '*.cfg' -exec cp -a {} "$APPDIR/usr/config/" \; 2>/dev/null || true

echo
echo "Plugins built:"
ls -1 "$APPDIR/usr/plugins" 2>/dev/null || echo "  (none)"

# --------------------------------------------------------------- AppRun ----
log "Writing AppRun"
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
# ePSXe AppImage launcher.
HERE="$(dirname "$(readlink -f "${0}")")"

export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH}"
# ePSXe resolves plugins and configs relative to $HOME/.epsxe.
export HOME="${HOME:-/tmp}"

if [ ! -d "$HOME/.epsxe/plugins" ]; then
  mkdir -p "$HOME/.epsxe"
  ln -sfn "${HERE}/usr/plugins" "$HOME/.epsxe/plugins"
  ln -sfn "${HERE}/usr/config"  "$HOME/.epsxe/config"
  # ePSXe looks for shaders in ~/.epsxe/shaders.
  [ -d "${HERE}/usr/shaders" ] && ln -sfn "${HERE}/usr/shaders" "$HOME/.epsxe/shaders"
fi

exec "${HERE}/usr/bin/epsxe_x64" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# Desktop entry + icon. appimagetool wants both in the AppDir root; they are
# also kept in the standard usr/ locations.
cat > "$APPDIR/epsxe.desktop" <<'DE'
[Desktop Entry]
Type=Application
Name=ePSXe PS1 Emulator
Comment=A PlayStation 1 emulator for 64-bit Linux
Icon=epsxe
Exec=epsxe
Terminal=false
Categories=Game;Emulator;
Keywords=PS1;PSX;ePSXe;PlayStation 1;
DE
cp "$APPDIR/epsxe.desktop" "$APPDIR/usr/share/applications/epsxe.desktop"

# Icon: reuse the upstream PNG, scaled to a regular 256x256.
if [ -f "$WORK/upstream/squashfs-root/epsxe.png" ]; then
  convert "$WORK/upstream/squashfs-root/epsxe.png" -background none -resize 256x256 \
    -gravity center -extent 256x256 \
    "$APPDIR/usr/share/icons/hicolor/256x256/apps/epsxe.png" 2>/dev/null || \
    cp "$WORK/upstream/squashfs-root/epsxe.png" \
       "$APPDIR/usr/share/icons/hicolor/256x256/apps/epsxe.png"
fi
[ -e "$APPDIR/usr/share/icons/hicolor/256x256/apps/epsxe.png" ] && \
  cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/epsxe.png" "$APPDIR/epsxe.png"

# ------------------------------------------------------------- AppImage ----
log "Running appimagetool"
APPIMAGETOOL="$(command -v appimagetool || echo /tmp/appimagetool)"
"$APPIMAGETOOL" --no-appstream "$APPDIR" "$OUT_DIR/ePSXe-${EPSXE_VER}-x86_64.AppImage"

echo
echo "Built: $OUT_DIR/ePSXe-${EPSXE_VER}-x86_64.AppImage"
ls -lh "$OUT_DIR"
