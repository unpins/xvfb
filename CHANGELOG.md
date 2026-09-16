# Changelog

## [Unreleased]

Initial release — Xvfb from `xorg-server` 21.1.22 as a single self-contained
binary, built natively for Linux, macOS, and Windows.

### Fixed

- On Windows, `xvfb :99` exited with `Cannot establish any listening sockets`
  and only started with `-listen tcp`. It now listens on TCP by default.
- On Windows, the embedded bitmap fonts were not served: clients saw 11 fonts
  instead of 509.
- On macOS, the `SECURITY` extension was missing; all three platforms now offer
  the same extensions, except `MIT-SHM` on Windows.
- `unpin install xvfb` no longer lists a nonexistent `Xserver` command.
- On Windows, the `Xvfb` alias is installed too.

### Added

- Builds for Linux (x86_64, aarch64, armv7l, i686, ppc64le, riscv64), macOS
  (x86_64, aarch64), and Windows.
- The keyboard layouts (`xkeyboard-config`) and the core `misc`/`cursor` bitmap
  fonts are embedded, and keymaps are compiled inside the server, so it needs no
  XKB directory, font path or `xkbcomp` on the machine.
- The `Xvfb` man page, embedded — read it with `unpin man xvfb Xvfb`.
