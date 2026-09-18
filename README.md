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

The binary is `xvfb`; `Xvfb` (the familiar capital-X server name) is installed as an alias.

## Usage

Run `xvfb` with [unpin](https://github.com/unpins/unpin):

```bash
unpin xvfb :99 -screen 0 1280x1024x24 &   # start a virtual display :99
DISPLAY=:99 your-gui-program               # point clients at it
```

To install it onto your PATH:

```bash
unpin install xvfb
```

On Windows the server listens on TCP instead of a local socket, so display `:N`
is port `6000+N` and clients connect with `DISPLAY=127.0.0.1:99`.

`unpin man xvfb Xvfb` covers the options specific to Xvfb (`-screen`,
`-pixdepths`, `-fbdir`, …). The options every X server shares (`-listen`, `-fp`,
`-ac`, `-nolisten`, …) are in upstream's
[Xserver(1)](https://www.x.org/releases/current/doc/man/man1/Xserver.1.xhtml).

Everything an X server normally reads from disk is **embedded in the binary** —
no `XKB`/keymap directory, no font path, no companion files to ship:

- **Keyboard layouts (XKB).** The full
  [`xkeyboard-config`](https://www.freedesktop.org/wiki/Software/XKeyboardConfig/)
  tree is embedded and the keymap compiler (`xkbcomp`) runs **in-process** — any
  RMLVO layout (`-keybd`, `setxkbmap`) compiles from the in-binary tree with no
  external `xkbcomp`.
- **Core fonts.** `fixed`, `cursor`, and the `misc` bitmap fonts are embedded at
  the default font path, so clients that ask for the built-in fonts work with no
  font server or font directory.

## Build locally

```bash
nix build github:unpins/xvfb
./result/bin/xvfb -help
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
  call it in-process (fork, then the spec and the compiled `.xkm` are handed
  back in memory on Linux and through short-lived temp files on macOS and
  Windows), so the full RMLVO → keymap pipeline runs from the embedded
  `xkeyboard-config` tree.

- **Embedded data.** The XKB rules and symbols (the `xkeyboard-config` tree)
  and the core bitmap fonts are packed into the binary. A live X server reads
  them from there only — no `/nix/store`, no system XKB/font directory.

- **Platforms, one binary each.**
  - **Linux** (every arch): the whole X server linked statically, XKB + fonts
    embedded.
  - **macOS**: every linked library is built in.
  - **Windows** via [Cosmopolitan](https://github.com/jart/cosmopolitan): the
    same X server. It listens on TCP by default, and it has no `MIT-SHM`
    extension (Windows has no System V shared memory).

- **Headless only.** This is `Xvfb` (virtual framebuffer), not a GPU/seat server
  — it renders to memory, needs no root, KMS, or DRM, and serves the core bitmap
  fonts. GL/GLX/DRI3/glamor are disabled; clients needing GLX get software
  rendering only where the client provides it.
