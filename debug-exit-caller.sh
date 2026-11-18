#!/usr/bin/env bash
# Catch whichever code calls exit() when a plugin config dialog is opened.
# Breaking on libc exit() is more reliable than guessing ePSXe function names.
set -euo pipefail

APPIMAGE="${1:-/opt/epsxe/ePSXe.AppImage}"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/epsxe-debug"
ROOT="$WORK/root"

if [ ! -x "$ROOT/usr/bin/epsxe_x64" ]; then
    echo "Extracting $APPIMAGE ..."
    rm -rf "$WORK"; mkdir -p "$WORK"
    ( cd "$WORK" && "$APPIMAGE" --appimage-extract >/dev/null 2>&1 )
    mv "$WORK/squashfs-root" "$ROOT"
fi

echo "Click the audio (or video) Configure button. Backtrace prints at exit()."
echo

# gdb itself must not see the bundled libcurl (breaks debuginfod), so clear
# LD_LIBRARY_PATH for gdb and set it for the inferior only.
exec env -u LD_LIBRARY_PATH DEBUGINFOD_URLS= \
    gdb -q \
        -ex 'set debuginfod enabled off' \
        -ex "set environment LD_LIBRARY_PATH $ROOT/usr/lib" \
        -ex 'set environment HOME '"$HOME" \
        -ex 'set pagination off' \
        -ex 'set confirm off' \
        -ex 'break exit' \
        -ex 'run' \
        -ex 'echo \n===== EXIT CALLED FROM =====\n' \
        -ex 'bt 20' \
        -ex 'quit' \
        "$ROOT/usr/bin/epsxe_x64"
