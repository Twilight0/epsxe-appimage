#!/usr/bin/env bash
# Build a self-contained ePSXe 2.0.5 AppImage for x86_64.
#
# ePSXe 2.0.5 is a closed-source 64-bit Linux binary that expects a
# pre-2019 runtime (ncurses 5, OpenSSL 1.0, libcurl with CURL_OPENSSL_3,
# SDL 1.2). None of those exist on a modern distro, so we bundle them.
#
# The upstream PSEmu Pro plugin set (Pete Bernert's PEOpS/XGL2/SoftX/OSS
# and padJoy) is 32-bit i386 only and cannot be loaded by the 64-bit
# binary, so the 64-bit plugins are built from the PCSX-Reloaded 1.9.95
# sources (the same source the Arch AUR 'epsxe' package uses).
#
# Usage: build.sh <output-dir>
set -euo pipefail

OUT_DIR="${1:?usage: build.sh <output-dir>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APPDIR="$WORK/ePSXe.AppDir"
EPSXE_VER=2.0.5
PLGN_VER=1.9.95
UBUNTU_POOL="http://archive.ubuntu.com/ubuntu/pool"

mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/plugins" \
         "$APPDIR/usr/config" "$APPDIR/usr/share/icons/hicolor/256x256/apps"

log() { printf '\n=== %s\n' "$*"; }

# ---------------------------------------------------------------- ePSXe ---
log "Fetching ePSXe ${EPSXE_VER} (official x86_64 build)"
curl -fsSL --retry 3 -o "$WORK/epsxe.zip" \
  "https://www.epsxe.com/files/ePSXe${EPSXE_VER//./}linux_x64.zip"
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
mkdir -p "$APPDIR/usr/share/doc/epsxe"
mv "$APPDIR/docs/"*.txt "$APPDIR/usr/share/doc/epsxe/" 2>/dev/null || true
rm -rf "$APPDIR/docs"

# --------------------------------------------------------------- shaders ---
log "Fetching shaders"
if curl -fsSL --retry 2 -o "$WORK/shaders.zip" "https://www.epsxe.com/files/shaders.zip"; then
  mkdir -p "$WORK/shaders" && unzip -q -o "$WORK/shaders.zip" -d "$WORK/shaders"
  if [ -d "$WORK/shaders/shaders" ]; then
    cp -r "$WORK/shaders/shaders/." "$APPDIR/usr/config/"
  else
    cp -r "$WORK/shaders/." "$APPDIR/usr/config/"
  fi
fi

# ------------------------------------------------- legacy runtime libs ----
# Ubuntu 16.04 (xenial) runtime: ncurses 5, OpenSSL 1.0, libcurl 7.47.
# These carry the exact SONAMEs and symbol versions ePSXe links against
# (NCURSES_5.0.19991023, CURL_OPENSSL_3, libcrypto.so.1.0.0).
log "Fetching legacy runtime libraries"
mkdir -p "$WORK/debs"
for u in \
  "main/c/curl/libcurl3_7.47.0-1ubuntu2.19_amd64.deb" \
  "main/o/openssl/libssl1.0.0_1.0.2g-1ubuntu4.20_amd64.deb" \
  "main/n/ncurses/libncurses5_6.0+20160213-1ubuntu1_amd64.deb" \
  "main/n/ncurses/libtinfo5_6.0+20160213-1ubuntu1_amd64.deb" ; do
  f="$WORK/debs/$(basename "$u")"
  curl -fsSL --retry 3 -o "$f" "$UBUNTU_POOL/$u"
done

mkdir -p "$WORK/debex"
for d in "$WORK"/debs/*.deb; do
  ar p "$d" data.tar.xz | tar -xJ -C "$WORK/debex"
done

# Collect the shared objects we need (plus their symlinks) into usr/lib.
collect() {
  local src="$1" name="$2"
  [ -e "$WORK/debex$src" ] || return 1
  cp -aL "$WORK/debex$src" "$APPDIR/usr/lib/$name" 2>/dev/null || \
    cp -a "$WORK/debex$src" "$APPDIR/usr/lib/$name"
}
for base in lib usr/lib; do
  for f in "$WORK/debex/$base/x86_64-linux-gnu"; do
    [ -d "$f" ] || continue
    for so in "$f"/libncurses.so.5* "$f"/libtinfo.so.5* "$f"/libtic.so.5* \
              "$f"/libcurl.so.4* "$f"/libcurl.so.3 "$f"/libssl.so.1.0.0* \
              "$f"/libcrypto.so.1.0.0*; do
      [ -e "$so" ] || continue
      cp -a "$so" "$APPDIR/usr/lib/" 2>/dev/null || true
    done
  done
done

# Fix up sonames/symlinks so the loader finds them.
cd "$APPDIR/usr/lib"
ln -sf libncurses.so.5.9 libncurses.so.5
ln -sf libtinfo.so.5.9 libtinfo.so.5
ln -sf libcrypto.so.1.0.0 libcrypto.so.1.0.0
ln -sf libssl.so.1.0.0 libssl.so.1.0.0
rm -f libcurl.so.3
[ -e libcurl.so.4.4.0 ] && ln -sf libcurl.so.4.4.0 libcurl.so.4
cd "$WORK"

# ---------------------------------------------------------- 64-bit plugins --
log "Building 64-bit plugins from PCSX-Reloaded ${PLGN_VER}"
git clone -q --depth 1 --branch "$PLGN_VER" \
  https://github.com/frealgagu/PCSX-Reloaded.git "$WORK/pcsxr"
cd "$WORK/pcsxr/pcsxr"

# Patches from the Arch AUR 'epsxe' package (modern toolchain fixes).
for p in Makefile.patch configure_ac.patch; do
  curl -fsSL -o "$WORK/$p" "https://aur.archlinux.org/cgit/aur.git/plain/$p?h=epsxe"
done
patch -p0 < "$WORK/Makefile.patch"
patch -p0 < "$WORK/configure_ac.patch"

cd "$WORK/pcsxr"
for p in pcsxr-fix-undefined-operations.patch peopsxgl_gpu_c.patch dfxvideo_cfg_c.patch; do
  curl -fsSL -o "$WORK/$p" "https://aur.archlinux.org/cgit/aur.git/plain/$p?h=epsxe"
  patch -Np1 -i "$WORK/$p" || echo "warning: $p did not apply cleanly"
done

cd "$WORK/pcsxr/pcsxr"
mkdir -p include

# Implicit-function-declaration fixes for modern GCC.
sed -ri 's|(#include "pad.h")|\1\n#include <sys/wait.h>|' plugins/dfinput/pad.c
sed -ri 's|(#include "stdafx.h")|\1\n#include <sys/wait.h>|' plugins/dfsound/cfg.c
sed -ri 's|(#include "cdr.h")|\1\n#include <sys/wait.h>|' plugins/dfcdrom/cdr.c
sed -ri 's|(#include "sio1.h")|\1\n#include <sys/wait.h>|' plugins/bladesio1/sio1.c
sed -ri 's|(#include "sio1.h")|\1\n#include <unistd.h>|' plugins/bladesio1/sio1.c
# ePSXe looks in ~/.epsxe, PCSX-Reloaded in ~/.pcsxr.
sed -i 's|\.pcsxr|.epsxe|g' gui/Linux.h
sed -i 's|/games/psemu/||g' plugins/peopsxgl/Makefile.am
sed -i 's|/psemu/||g' plugins/peopsxgl/Makefile.am

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

make -j"$(nproc)" >/dev/null 2>&1 || make >"$WORK/make.log" 2>&1 || {
  echo "plugin build failed:"; tail -30 "$WORK/make.log"; exit 1; }

cd "$APPDIR/usr/plugins"
for so in *.so; do
  [ -e "$so" ] || continue
  mv "$so" "$APPDIR/usr/plugins/" 2>/dev/null || true
done
# Plugin .so files are named like libgpuPeopsXGL.so.1.0.0 etc.
cp -a "$APPDIR/usr/plugins"/*.so* "$APPDIR/usr/plugins/" 2>/dev/null || true
find "$APPDIR/usr/plugins" -name '*.la' -delete
find "$APPDIR/usr/plugins" -type d -empty -delete

# Configs produced by the plugin builds.
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
fi

exec "${HERE}/usr/bin/epsxe_x64" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# Desktop entry + icon.
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
mv "$APPDIR/epsxe.desktop" "$APPDIR/usr/share/applications/epsxe.desktop" 2>/dev/null || {
  mkdir -p "$APPDIR/usr/share/applications"
  mv "$APPDIR/epsxe.desktop" "$APPDIR/usr/share/applications/epsxe.desktop"
}

# Icon: reuse the upstream PNG from the AppImage the package used before.
if [ ! -e "$APPDIR/usr/share/icons/hicolor/256x256/apps/epsxe.png" ]; then
  curl -fsSL --retry 2 -o "$WORK/icon.png" \
    "https://github.com/amirzaim/epsxe-appimage/releases/download/epsxe/ePSXe_PS1_Emulator-x86_64.AppImage" || true
  if [ -s "$WORK/icon.png" ]; then
    (cd "$WORK" && chmod +x icon.png && ./icon.png --appimage-extract >/dev/null 2>&1) || true
    if [ -f "$WORK/squashfs-root/epsxe.png" ]; then
      convert "$WORK/squashfs-root/epsxe.png" -background none -resize 256x256 \
        -gravity center -extent 256x256 \
        "$APPDIR/usr/share/icons/hicolor/256x256/apps/epsxe.png" 2>/dev/null || \
        cp "$WORK/squashfs-root/epsxe.png" \
           "$APPDIR/usr/share/icons/hicolor/256x256/apps/epsxe.png"
    fi
  fi
fi

# ------------------------------------------------------------- AppImage ----
log "Running appimagetool"
APPIMAGETOOL="$(command -v appimagetool || echo /tmp/appimagetool)"
"$APPIMAGETOOL" --no-appstream "$APPDIR" "$OUT_DIR/ePSXe-${EPSXE_VER}-x86_64.AppImage"

echo
echo "Built: $OUT_DIR/ePSXe-${EPSXE_VER}-x86_64.AppImage"
ls -lh "$OUT_DIR"
