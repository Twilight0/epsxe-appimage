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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPSXE_VER=2.0.5
PLGN_VER=1.9.95
UBUNTU_POOL="http://archive.ubuntu.com/ubuntu/pool"
DEBIAN_POOL="http://deb.debian.org/debian/pool/main/o/openldap"

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
      # OpenLDAP: replaced by the Debian build, which carries the LDAP_2.4_2
      # version script that libcurl requires.
      libldap*|liblber*) continue ;;
      # Wayland: the upstream bundle's 18.04 libwayland-client is older than
      # the host's libwayland-cursor, which then fails on wl_proxy_marshal_flags.
      # Mixing the two breaks; take the host's consistent set instead.
      libwayland-*) continue ;;
      libxkbcommon.so.0) continue ;;
      # Libraries that load external modules from an absolute path baked in at
      # build time. The bundled Ubuntu copies look for Ubuntu paths
      # (/usr/lib/x86_64-linux-gnu/alsa-lib, .../gdk-pixbuf-2.0/2.10.0,
      # .../gio/modules) which do not exist on Arch, so ALSA and the pixbuf
      # loaders silently fail. Let the host provide them.
      libasound.so*) continue ;;
      libgdk_pixbuf*) continue ;;
      libgio-2.0*|libgobject-2.0*|libgmodule-2.0*|libglib-2.0*|libgthread-2.0*) continue ;;
      libgtk-3*|libgdk-3*|libgdk-x11*|libgdk_pixbuf*) continue ;;
      libatk-1.0*|libatk-bridge*|libatspi*|libcairo*|libpango*|libharfbuzz*) continue ;;
      libfontconfig*|libfreetype*|libexpat*|libpixman*) continue ;;
      libdbus-1*|libepoxy*|libfribidi*|libthai*|libdatrie*) continue ;;
      # X11 and the GL stack: the host provides a set that matches its own
      # X server, its own drivers and its own libGLdispatch. Shipping a
      # second, older copy inside the AppImage mixes two versions in one
      # process, which breaks input (SDL/Xlib keyboard events) and rendering.
      libX11*|libXext*|libXfixes*|libXi.*|libXrender*|libXrandr*|libXcursor*| \
      libXinerama*|libXss*|libXxf86vm*|libXtst*|libXau*|libXdmcp*|libxcb*| \
      libGL*|libEGL*|libgbm*|libdrm*|libOpenGL*|libglapi*) continue ;;
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

# OpenLDAP from Debian rather than Ubuntu: Debian builds it with the
# LDAP_2.4_2 version script, which is what libcurl requires (the Ubuntu
# build has no version information, which the loader warns about).
fetch "$DEBIAN_POOL/libldap-2.4-2_2.4.57+dfsg-3+deb11u1_amd64.deb" \
      "$WORK/debs/libldap.deb"

mkdir -p "$WORK/debex"
for d in "$WORK"/debs/*.deb; do
  ar p "$d" data.tar.xz | tar -xJ -C "$WORK/debex"
done

for dir in "$WORK/debex/lib/x86_64-linux-gnu" "$WORK/debex/usr/lib/x86_64-linux-gnu"; do
  [ -d "$dir" ] || continue
  for so in "$dir"/libncurses.so.5* "$dir"/libtinfo.so.5* "$dir"/libtic.so.5* \
            "$dir"/libssl.so.1.0.0* "$dir"/libcrypto.so.1.0.0* \
            "$dir"/libssl.so.1.1* "$dir"/libcrypto.so.1.1* \
            "$dir"/libunistring.so.2* \
            "$dir"/libldap_r-2.4.so.2* "$dir"/liblber-2.4.so.2* \
            "$dir"/libldap-2.4.so.2*; do
    [ -e "$so" ] || continue
    cp -aL "$so" "$APPDIR/usr/lib/" 2>/dev/null || true
  done
done

echo "  bundled $(find "$APPDIR/usr/lib" -type f | wc -l) libraries"

# Fail the build if the emulator's libraries do not all resolve. The real
# test is the dynamic loader's own view: run ldd with the AppImage library
# path in front and look for anything left unresolved.
log "Verifying that all required libraries resolve"
if command -v ldd >/dev/null 2>&1; then
  unresolved="$(LD_LIBRARY_PATH="$APPDIR/usr/lib" ldd "$APPDIR/usr/bin/epsxe_x64" 2>/dev/null \
    | grep -i "not found" | awk '{print $1}' | sort -u || true)"
  if [ -n "$unresolved" ]; then
    echo "Error: unresolved libraries:$unresolved" >&2
    exit 1
  fi
  echo "  all dependencies resolve"
else
  echo "  (ldd unavailable, skipping the dependency check)"
fi

# ---------------------------------------------------------------- cheats ---
# ePSXe resolves cheats from ~/.epsxe/cheats/<GAME_CODE>.txt and downloads
# them on demand from http://epsxe.com/cheats/<PREFIX>/<CODE>.txt. Bundling
# the whole library makes every game playable with codes offline.
log "Fetching the cheat library"
mkdir -p "$APPDIR/usr/cheats"
CHEAT_CACHE="$CACHE/cheats.tar.gz"
if [ ! -s "$CHEAT_CACHE" ]; then
  mkdir -p "$WORK/cheats"
  for prefix in ESPM SCED SCES SCPS SCUS SIPS SLES SLPM SLPS SLUS; do
    base="http://epsxe.com/cheats/$prefix"
    names="$(curl -fsSL --max-time 60 "$base/" 2>/dev/null \
      | grep -oE '>[A-Za-z0-9_.-]+\.txt<' | tr -d '><' | sort -u || true)"
    [ -n "$names" ] || continue
    mkdir -p "$WORK/cheats/$prefix"
    printf '%s\n' "$names" | xargs -P 16 -I{} \
      curl -fsSL --max-time 60 --retry 3 --retry-all-errors \
        -o "$WORK/cheats/$prefix/{}" "$base/{}" || true
  done
  tar -czf "$CHEAT_CACHE" -C "$WORK/cheats" .
fi
tar -xzf "$CHEAT_CACHE" -C "$APPDIR/usr/cheats"
echo "  bundled $(find "$APPDIR/usr/cheats" -name '*.txt' | wc -l) cheat files"

# ------------------------------------------------------- extra shaders -----
# Pete Bernert's OGL2 shader packs, in the same gpuCore.* format ePSXe's
# internal GPU core expects (the upstream AppImage ships the vendor's
# shaders.zip; these add the rest).
log "Fetching additional shader packs"
mkdir -p "$APPDIR/usr/shaders"
for n in brightness brokenglass gray luigi_aa median_glow median multitexdemo \
         rotate scale2x simpleblur; do
  zip="$WORK/shader-$n.zip"
  fetch "http://www.pbernert.com/pete_ogl2_shader_$n.zip" "$zip" || continue
  rm -rf "$WORK/sx"; mkdir -p "$WORK/sx"
  unzip -q -o "$zip" -d "$WORK/sx" 2>/dev/null || continue
  slv="$(find "$WORK/sx" -name '*.slv' | head -1)"
  slf="$(find "$WORK/sx" -name '*.slf' | head -1)"
  [ -n "$slv" ] && [ -n "$slf" ] || continue
  out="$APPDIR/usr/shaders/Pete-$n"
  mkdir -p "$out"
  cp "$slv" "$out/gpuCore.slv"
  cp "$slf" "$out/gpuCore.slf"
  cat > "$out/gpuCore.ini" <<EOF
name=$n
version=1
license=GPLv2
copyright=Pete Bernert
filter_linear=0
EOF
done
# The guest shader pack holds several variants at once.
if fetch "http://www.pbernert.com/pete_ogl2_guest_shaders_v1.zip" "$WORK/guest.zip"; then
  rm -rf "$WORK/gx"; mkdir -p "$WORK/gx"
  unzip -q -o "$WORK/guest.zip" -d "$WORK/gx" 2>/dev/null || true
  for d in "$WORK/gx"/*/; do
    [ -d "$d" ] || continue
    slv="$(find "$d" -maxdepth 1 -name '*.slv' | head -1)"
    slf="$(find "$d" -maxdepth 1 -name '*.slf' | head -1)"
    [ -n "$slv" ] && [ -n "$slf" ] || continue
    name="$(basename "$d" | sed 's/ shader$//' | tr ' ' '_')"
    out="$APPDIR/usr/shaders/Pete-$name"
    mkdir -p "$out"
    cp "$slv" "$out/gpuCore.slv"; cp "$slf" "$out/gpuCore.slf"
    cat > "$out/gpuCore.ini" <<EOF
name=$name
version=1
license=GPLv2
copyright=Pete Bernert
filter_linear=0
EOF
  done
fi
echo "  bundled $(find "$APPDIR/usr/shaders" -mindepth 1 -maxdepth 1 -type d | wc -l) shader packs"

# ---------------------------------------------------------- 64-bit plugins --
log "Building 64-bit plugins from PCSX-Reloaded ${PLGN_VER}"
git clone -q --depth 1 --branch "$PLGN_VER" \
  https://github.com/frealgagu/PCSX-Reloaded.git "$WORK/pcsxr"
cd "$WORK/pcsxr/pcsxr"

# ePSXe compatibility patches from the Arch AUR 'epsxe' package.
#
# 1. texture.c contains "*ta++=*(ta-(g_x2-g_x1));", which is undefined
#    behaviour (two unsequenced accesses to ta) and corrupts memory.
# 2. the config GUI path has to point at ePSXe's ~/.epsxe, not ~/.pcsxr.
curl -fsSL --max-time 30 -o "$WORK/undefined-ops.patch" \
  "https://aur.archlinux.org/cgit/aur.git/plain/pcsxr-fix-undefined-operations.patch?h=epsxe"
(cd "$WORK/pcsxr" && patch -Np1 -i "$WORK/undefined-ops.patch") || \
  echo "warning: undefined-operations patch did not apply"

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
# The plugin's config GUI lives next to the plugin itself. The source path is
# "%s/.pcsxr/plugins/cfg/cfgpeopsxgl" and the plugin only falls back to
# PATH-relative lookup, so it must be rewritten or ePSXe reports
# "ERROR: cfgpeopsxgl file not found!".
sed -i 's|%s/\.pcsxr/plugins/cfg/cfgpeopsxgl|%s/.epsxe/plugins/cfgpeopsxgl|' \
  plugins/peopsxgl/gpu.c
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
mkdir -p "$APPDIR/usr/share/epsxe"
cp "$SCRIPT_DIR/epsxe.css" "$APPDIR/usr/share/epsxe/epsxe.css"
cat > "$APPDIR/usr/share/epsxe/config.example" <<'CFG'
# ePSXe settings.
#
# Copy to /etc/epsxe.conf (system wide) or ~/.epsxe/epsxe.conf (per user) to
# have the settings apply to desktop menu launches as well.
#
# Everything lives under ~/.epsxe/, where ePSXe keeps its own data, so there
# is a single configuration location.
#
# One KEY=VALUE per line.

# Force a theme for ePSXe only. ePSXe 2.0.5 uses stock GTK3 widgets, and
# under a dark desktop theme some labels (e.g. in the game directory
# chooser) are hard to read. "Adwaita" renders them light and readable.
#EPSXE_GTK_THEME=Adwaita

# Use the dark variant of the forced theme.
#EPSXE_GTK_DARK=1

# Extra CSS applied to ePSXe only. Put it in ~/.epsxe/epsxe.css to replace
# the bundled stylesheet.
#EPSXE_GTK_CSS=$HOME/.epsxe/epsxe.css

# SDL2 backend. Needed on Wayland: ePSXe draws through X11/GLX while the
# input plugin reads the keyboard through SDL2, so SDL2 must use the X11
# backend too or no key reaches the emulator.
#SDL_VIDEODRIVER=x11
CFG

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
# ePSXe AppImage launcher.
HERE="$(dirname "$(readlink -f "${0}")")"

export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH}"
# ePSXe resolves plugins, configs, cheats and shaders relative to $HOME/.epsxe.
export HOME="${HOME:-/tmp}"

# --- single configuration location -------------------------------------
# ePSXe hardcodes $HOME/.epsxe/ (it reads no other environment variable, so
# the path cannot be overridden), but everything it stores there is user
# configuration and data. Keep one location by making ~/.epsxe a symlink to
# ~/.config/epsxe, the conventional place for user configuration.
#
# The migration runs once: an existing ~/.epsxe directory is moved into
# ~/.config/epsxe, and only when that target does not already exist. Both
# present means the user arranged it deliberately, so it is left alone.
if [ ! -L "$HOME/.epsxe" ]; then
  if [ ! -e "$HOME/.epsxe" ]; then
    mkdir -p "$HOME/.config/epsxe"
    ln -s ".config/epsxe" "$HOME/.epsxe" 2>/dev/null || true
  elif [ ! -e "$HOME/.config/epsxe" ]; then
    echo "epsxe: moving ~/.epsxe to ~/.config/epsxe (single config location)"
    mkdir -p "$HOME/.config"
    _n_before=$(find "$HOME/.epsxe" -type f 2>/dev/null | wc -l)
    if cp -a "$HOME/.epsxe" "$HOME/.config/epsxe" 2>/dev/null; then
      _n_after=$(find "$HOME/.config/epsxe" -type f 2>/dev/null | wc -l)
      if [ "$_n_after" -lt "$_n_before" ]; then
        echo "epsxe: copy incomplete ($_n_after of $_n_before files), keeping ~/.epsxe" >&2
        rm -rf "$HOME/.config/epsxe" 2>/dev/null || true
      else
        rm -rf "$HOME/.epsxe"
        ln -s ".config/epsxe" "$HOME/.epsxe" 2>/dev/null || true
        echo "epsxe: done ($_n_after files). ~/.epsxe is now a symlink to ~/.config/epsxe"
      fi
    else
      echo "epsxe: could not migrate, keeping ~/.epsxe as a directory" >&2
      rm -rf "$HOME/.config/epsxe" 2>/dev/null || true
    fi
  fi
fi

# --- configuration -----------------------------------------------------
# Persistent settings, so the fixes also apply when ePSXe is started from
# the desktop menu (a menu launch does not inherit the shell environment).
#
#   system wide : /etc/epsxe.conf
#   per user    : ~/.epsxe/epsxe.conf
#
# Everything lives under ~/.epsxe/, which is where ePSXe keeps its own data
# (it hardcodes $HOME/.epsxe/ and reads no other environment variable), so
# there is a single configuration location instead of two conventions.
#
# Format: one KEY=VALUE per line, shell syntax. The user file wins.
#
#   EPSXE_GTK_THEME=Adwaita        force a theme for ePSXe only
#   EPSXE_GTK_DARK=1               use the dark variant of a forced theme
#   EPSXE_GTK_CSS=/path/to.css     extra CSS for ePSXe only
#   SDL_VIDEODRIVER=x11            SDL2 backend (needed on Wayland)
for _cfgfile in /etc/epsxe.conf "$HOME/.epsxe/epsxe.conf"; do
  [ -r "$_cfgfile" ] || continue
  # shellcheck disable=SC1090
  . "$_cfgfile"
done

# --- input on Wayland --------------------------------------------------
# ePSXe opens its window through X11/GLX, but the input plugin (dfinput)
# reads the keyboard through SDL2. Under a Wayland session SDL2 defaults to
# its Wayland backend and creates a separate surface, so it never receives
# the key events of the X11 window the emulator actually draws in: ESC and
# every other key end up in limbo.
#
# Pointing SDL2 at the X11 backend puts input and rendering on the same
# X connection (XWayland), which restores the keyboard.
if [ -z "${SDL_VIDEODRIVER:-}" ] && [ -n "${DISPLAY:-}" ]; then
  export SDL_VIDEODRIVER=x11
fi

# --- ~/.epsxe seeding --------------------------------------------------
# ePSXe resolves plugins, configs, cheats and shaders relative to
# $HOME/.epsxe. Seed them on first run.
#
# The check is "is the content actually there", not "does the directory
# exist": a previous run could have left an empty plugins/ directory, and
# then the plugins would never be copied and ePSXe would silently fall
# back to its internal GPU core - whose ESC/menu handling does not work.
#
# Copy rather than symlink: the AppImage is mounted in a temporary
# directory that disappears when it exits, so a symlink would dangle
# afterwards.
_needs_seed=0
for d in plugins config shaders cheats; do
  [ -d "${HERE}/usr/$d" ] || continue
  # Count recursively: the cheats live in per-region subdirectories.
  _want=$(find "${HERE}/usr/$d" -type f | wc -l)
  _have=$(find "$HOME/.epsxe/$d" -type f 2>/dev/null | wc -l)
  if [ "$_want" -gt 0 ] && [ "$_have" -lt "$_want" ]; then
    _needs_seed=1
    echo "epsxe: seeding ~/.epsxe/$d ($_have of $_want files present)"
  fi
done

if [ "$_needs_seed" = "1" ]; then
  echo "epsxe: seeding ~/.epsxe (plugins, config, shaders, cheats)..."
  mkdir -p "$HOME/.epsxe"
  for d in plugins config shaders cheats; do
    [ -d "${HERE}/usr/$d" ] || continue
    rm -rf "$HOME/.epsxe/$d"
    cp -r "${HERE}/usr/$d" "$HOME/.epsxe/$d"
  done
  echo "epsxe: done."
fi

# Refresh individual bundled files that are out of date, without touching
# anything else: the plugins directory also holds the settings files the
# plugin writes (.cfg), and those must survive an upgrade.
for d in plugins config; do
  [ -d "${HERE}/usr/$d" ] || continue
  (cd "${HERE}/usr/$d" && find . -type f | while IFS= read -r _f; do
    _src="${HERE}/usr/$d/$_f"
    _dst="$HOME/.epsxe/$d/$_f"
    if [ ! -f "$_dst" ] || ! cmp -s "$_src" "$_dst"; then
      mkdir -p "$(dirname "$_dst")"
      cp -p "$_src" "$_dst" 2>/dev/null && \
        echo "epsxe: refreshed $d/${_f#./}"
    fi
  done)
done

# Make the settings file discoverable: drop a documented example next to
# ePSXe's own data, but never overwrite one the user has edited.
if [ ! -e "$HOME/.epsxe/epsxe.conf" ] && [ -f "${HERE}/usr/share/epsxe/config.example" ]; then
  mkdir -p "$HOME/.epsxe"
  cp "${HERE}/usr/share/epsxe/config.example" "$HOME/.epsxe/epsxe.conf.example"
fi

# --- select the bundled plugins -----------------------------------------
# ePSXe defaults to its internal cores (VideoPlugin = GPUCORE), which have
# no on-the-fly menu: ESC does nothing, and the only way out is the mouse
# in the GTK window. The ESC menu lives in the external Pete GPU plugin.
#
# ePSXe resolves a plugin as $HOME/.epsxe/plugins/<name>, so point the
# config at the bundled ones. Names are taken from the files present, so
# this survives a rebuild.
#
# The input plugin is deliberately NOT selected: libDFInput.so calls
# XInternAtom() on the X display ePSXe hands it, and ePSXe 2.0.5 renders
# through SDL 1.2 and passes none - the plugin segfaults in InitKeyboard().
# The internal input core works and still forwards keys to the GPU plugin,
# which is what the ESC menu needs.
#
# epsxerc only exists after ePSXe has run once, so this runs on every start
# and rewrites the config each time (it is idempotent).
_select_plugins() {
  [ -f "$HOME/.epsxe/epsxerc" ] || return 0
  _rc="$HOME/.epsxe/epsxerc"
  for _pair in \
    "VideoPlugin:libpeopsxgl.so" \
    "SoundPlugin:libDFSound.so" ; do
    _key="${_pair%%:*}"
    _val="${_pair#*:}"
    [ -f "$HOME/.epsxe/plugins/$_val" ] || continue
    if ! grep -q "^$_key = $_val$" "$_rc"; then
      if grep -q "^$_key = " "$_rc"; then
        sed -i "s|^$_key = .*|$_key = $_val|" "$_rc"
      else
        printf '%s = %s\n' "$_key" "$_val" >> "$_rc"
      fi
      echo "epsxe: using the bundled plugin $_val"
    fi
  done
  # Never leave the crashing input plugin selected.
  for _key in InputPlugin Input2Plugin; do
    if grep -q "^$_key = libDFInput" "$_rc"; then
      sed -i "s|^$_key = .*|$_key = INPUTCORE|" "$_rc"
      echo "epsxe: reverted $_key to the internal core"
    fi
  done
}

# --- theming -----------------------------------------------------------
# ePSXe 2.0.5 uses stock GTK3 widgets. Under a dark desktop theme the
# labels of some dialogs (notably the game directory chooser) end up
# unreadable, and there is no in-app setting for it.
#
# EPSXE_GTK_THEME  force a theme for ePSXe only (e.g. "Adwaita" for a
#                  light, high-contrast rendering). Unset = use the
#                  desktop theme.
# EPSXE_GTK_CSS    path to a CSS file appended to ePSXe's own user.css.
# EPSXE_GTK_DARK=1 set the theme's dark variant (only meaningful together
#                  with EPSXE_GTK_THEME).
if [ -n "${EPSXE_GTK_THEME:-}" ]; then
  export GTK_THEME="$EPSXE_GTK_THEME"
  [ "${EPSXE_GTK_DARK:-0}" = "1" ] && export GTK_THEME="$EPSXE_GTK_THEME:dark"
fi

if [ -n "${EPSXE_GTK_CSS:-}" ] && [ -f "$EPSXE_GTK_CSS" ]; then
  _css="$EPSXE_GTK_CSS"
elif [ "${EPSXE_GTK_CSS:-}" = "none" ]; then
  _css=""
elif [ -f "$HOME/.epsxe/epsxe.css" ]; then
  # A user stylesheet in the ePSXe data directory replaces ours.
  _css="$HOME/.epsxe/epsxe.css"
else
  # Our own readability fixes, applied on top of the desktop's user.css.
  _css="${HERE}/usr/share/epsxe/epsxe.css"
fi

if [ -n "${_css:-}" ] && [ -f "$_css" ]; then
  # A private XDG_CONFIG_HOME keeps the override scoped to ePSXe: the
  # desktop's own GTK settings are copied in, ours are appended.
  _cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  _priv="$(mktemp -d)"
  mkdir -p "$_priv/gtk-3.0"
  for _f in settings.ini user.css gtk.css; do
    [ -f "$_cfg/gtk-3.0/$_f" ] && cp "$_cfg/gtk-3.0/$_f" "$_priv/gtk-3.0/" || true
  done
  cat "$_css" >> "$_priv/gtk-3.0/user.css" 2>/dev/null || \
    cp "$_css" "$_priv/gtk-3.0/user.css"
  export XDG_CONFIG_HOME="$_priv"
fi

# --- quitting ----------------------------------------------------------
# ePSXe 2.0.5's Linux port never connects WM_DELETE_WINDOW, so the window's
# close button is ignored. SIGTERM would also kill it mid-write of a
# memory card, so the quit helper asks politely first and only forces the
# issue if the emulator ignores the request.
quit_epsxe() {
  _pids="$(pgrep -f 'epsxe_x64' || true)"
  if [ -z "$_pids" ]; then
    echo "epsxe is not running" >&2
    return 1
  fi
  for _p in $_pids; do kill -TERM "$_p" 2>/dev/null || true; done
  sleep 2
  for _p in $(pgrep -f 'epsxe_x64' || true); do kill -KILL "$_p" 2>/dev/null || true; done
  echo "epsxe closed"
}

case "${1:-}" in
  --quit)
    shift
    quit_epsxe
    exit $?
    ;;
esac

# ePSXe reads ~/.epsxe/epsxerc at startup and writes it back on exit, so
# the plugin selection has to happen before the emulator is started. On the
# very first run the file does not exist yet; ePSXe then creates it with
# the internal cores, and the next run picks up the bundled plugins.
_select_plugins

exec "${HERE}/usr/bin/epsxe_x64" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"
# A standalone quit helper, also usable when ePSXe was started from the
# menu or from another terminal.
cat > "$APPDIR/epsxe-quit" <<'QUIT'
#!/bin/sh
# Ask a running ePSXe to close.
#
# ePSXe 2.0.5's Linux port never connects WM_DELETE_WINDOW, so the window's
# close button does nothing. SIGTERM first (ePSXe saves its memory cards on
# exit), SIGKILL only if it ignores that.
_pids="$(pgrep -f 'epsxe_x64' || true)"
if [ -z "$_pids" ]; then
  echo "epsxe is not running" >&2
  exit 1
fi
for _p in $_pids; do kill -TERM "$_p" 2>/dev/null || true; done
sleep 2
for _p in $(pgrep -f 'epsxe_x64' || true); do kill -KILL "$_p" 2>/dev/null || true; done
echo "epsxe closed"
QUIT
chmod +x "$APPDIR/epsxe-quit"

# Desktop entry + icon. appimagetool wants both in the AppDir root; they are
# also kept in the standard usr/ locations.
cat > "$APPDIR/epsxe.desktop" <<'DE'
[Desktop Entry]
Type=Application
Name=ePSXe PS1 Emulator
Comment=A PlayStation 1 emulator for 64-bit Linux
Icon=epsxe
Exec=epsxe %U
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
