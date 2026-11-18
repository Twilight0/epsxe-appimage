#!/usr/bin/env bash
# Catch the code path that ends ePSXe when a plugin config dialog is opened.
#
# Running gdb on the AppImage itself does not work: gdb attaches to the small
# AppImage launcher, so breakpoints on ePSXe's own functions are never set
# ("Function ... not defined"). This extracts the AppImage and debugs the real
# binary instead.
#
# Usage: ./debug-config-quit.sh
#   1. ePSXe starts under gdb
#   2. click the audio (or video) Configure button
#   3. when ePSXe exits, the backtrace is printed
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

BIN="$ROOT/usr/bin/epsxe_x64"
echo "Debugging: $BIN"
echo
echo "Click the audio/video Configure button. The backtrace prints when it exits."
echo

exec env HOME="$HOME" LD_LIBRARY_PATH="$ROOT/usr/lib" \
    gdb -q \
        -ex 'set pagination off' \
        -ex 'set confirm off' \
        -ex 'set debuginfod enabled off' \
        -ex 'break on_window_main_destroy' \
        -ex 'break on_exit_activate' \
        -ex 'catch signal SIGSEGV' \
        -ex 'catch signal SIGABRT' \
        -ex 'run' \
        -ex 'echo \n===== BACKTRACE =====\n' \
        -ex 'bt' \
        -ex 'info registers rip' \
        --args "$BIN" "$@"
