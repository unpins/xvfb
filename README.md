# xvfb

[Xvfb](https://www.x.org/releases/current/doc/man/man1/Xvfb.1.xhtml) — the X
virtual framebuffer display server: a full X11 server that renders to memory
instead of a real screen, for running GUI programs and test suites headlessly. A
single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/xvfb/actions/workflows/xvfb.yml/badge.svg)](https://github.com/unpins/xvfb/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install xvfb`.

The binary is `Xvfb` (capital X), the standard X-server name.

## Usage

Run `Xvfb` with [unpin](https://github.com/unpins/unpin):

```bash
unpin xvfb :99 -screen 0 1280x1024x24 &   # start a virtual display :99
DISPLAY=:99 your-gui-program               # point clients at it
```

To install it onto your PATH:

```bash
unpin install xvfb
```

Everything an X server normally reads from disk is **embedded in the binary** —
no `XKB`/keymap directory, no font path, no companion files to ship:

- **Keyboard layouts (XKB).** The full
  [`xkeyboard-config`](https://www.freedesktop.org/wiki/Software/XKeyboardConfig/)
  tree is embedded and the keymap compiler (`xkbcomp`) runs **in-process** — any
  RMLVO layout (`-keybd`, `setxkbmap`) compiles from the in-binary tree with no
  external `xkbcomp` and nothing written to `/tmp`.
- **Core fonts.** `fixed`, `cursor`, and the `misc` bitmap fonts are embedded at
  the default font path, so clients that ask for the built-in fonts work with no
  font server or font directory.

## Build locally

```bash
nix build github:unpins/xvfb
./result/bin/Xvfb -help
```

Or run directly:

```bash
nix run github:unpins/xvfb -- :99 -screen 0 800x600x24
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/xvfb/releases) page has standalone binaries for manual download.

## Build notes

- **In-process xkbcomp (every keymap).** A normal X server forks an external
  `xkbcomp` to turn the selected layout into a compiled keymap. There is no
  external binary in a single-file build, so the entire client-side XKB stack
  (xkbcomp's sources plus the display-free struct/IO members lifted straight from
  `libX11`/`libxkbfile`) is bundled into one self-contained object that exports a
  single entry point and depends on nothing but libc. `RunXkbComp` is patched to
  call it in-process (fork + an in-memory spec/`.xkm` handoff), so the full RMLVO
  → keymap pipeline runs from the embedded `xkeyboard-config` tree.

- **Embedded data via the VFS (unpin-vfs).** The server opens its XKB rules,
  symbols, and font files with `open`/`fopen`/`opendir`. The `xkeyboard-config`
  tree and core bitmap fonts are packed into a ZIP appended at the binary's EOF
  and served by the shared [unpin-vfs](https://github.com/unpins/unpin) core. On
  Linux the libc file calls are routed through the VFS with `ld --wrap`; on macOS
  (no `--wrap` for Mach-O) the server's own objects are rewritten with
  `llvm-objcopy --redefine-sym` and relinked; on Windows the data lives in the
  Cosmopolitan APE's native `/zip` store. A live X server reads from the in-binary
  mount only — no `/nix/store`, no system XKB/font directory.

- **Three platform paths, one binary each.**
  - **Linux** (static-musl, every arch): the whole X server linked statically,
    XKB + fonts embedded, `file` reports `statically linked`, no `/nix/store`
    closure.
  - **macOS** (Mach-O, libSystem-only): not pure `pkgsStatic` (the X stack's
    meson/python toolchain can't link statically on macOS) — built with the
    dynamic darwin stdenv but with every linked library swapped to its
    `pkgsStatic` `.a`, yielding a libSystem-only Mach-O.
  - **Windows** via [Cosmopolitan](https://github.com/jart/cosmopolitan): the
    same X server compiled to an APE and apelinked to a `Xvfb.exe` PE32+, with
    the data served from the APE's native `/zip`.

- **Headless only.** This is `Xvfb` (virtual framebuffer), not a GPU/seat server
  — it renders to memory, needs no root, KMS, or DRM, and serves the core bitmap
  fonts. GL/GLX/DRI3/glamor are disabled; clients needing GLX get software
  rendering only where the client provides it.
