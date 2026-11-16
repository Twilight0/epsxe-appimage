# ePSXe AppImage (x86_64)

A self-contained [ePSXe 2.0.5](https://epsxe.com) AppImage for 64-bit Linux,
with the legacy runtime libraries and 64-bit plugins bundled.

## Why this exists

ePSXe 2.0.5 is a closed-source 64-bit Linux binary from 2010 that expects a
pre-2019 runtime:

| Requirement | Modern distros | Here |
|---|---|---|
| `libncurses.so.5`, `libtinfo.so.5` (SONAME `NCURSES_5.0.19991023`) | ncurses 6 only | bundled (ncurses 5.9) |
| `libcrypto.so.1.0.0`, `libssl.so.1.0.0` | OpenSSL 3 only | bundled (OpenSSL 1.0.2) |
| `libcurl.so.4` with `CURL_OPENSSL_3` | curl 8 (`CURL_OPENSSL_4`) | bundled (curl 7.47) |
| `libSDL-1.2.so.0` | SDL 2 only | bundled (SDL 1.2) |

Without these, the binary dies at startup with
`error while loading shared libraries`.

## Plugins

The upstream PSEmu Pro plugin set (Pete Bernert's P.E.Op.S. SoftX / MesaGL /
OSS, Pete's XGL2, and padJoy) is published as **32-bit i386 binaries only**,
so a 64-bit ePSXe cannot load them. The bundled plugins are therefore built
from the [PCSX-Reloaded 1.9.95](https://github.com/frealgagu/PCSX-Reloaded)
sources — the same source the Arch `epsxe` package uses — which produce
64-bit equivalents.

ePSXe resolves plugins relative to `$HOME/.epsxe/`; `AppRun` links
`~/.epsxe/plugins` and `~/.epsxe/config` to the bundled directories on first
run.

## Usage

```bash
./ePSXe-2.0.5-x86_64.AppImage
```

You must supply your own PS1 BIOS (`~/.epsxe/bios/`); it is not bundled.

## Build

```bash
./build.sh <output-dir>
```

Requires `appimagetool`, `git`, `patch`, `autoconf`, `intltool`, ImageMagick,
and the GTK3/GL development headers.

## Credits

* ePSXe — © ePSXe / Ark Pearson. Not affiliated with this project.
* PCSX-Reloaded plugin sources — LGPL, © the PCSX-Reloaded authors.
