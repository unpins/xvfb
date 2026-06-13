# Linux (static-musl) Xvfb server derivation: the customised xorg-server with the
# in-process xkbcomp blob + the VFS reader (vfs.c/miniz via `ld --wrap`) linked
# in. It does NOT embed the xkb/font data or strip itself — the flake delegates
# that to nix-lib's withUnpinEmbed (one self-EOF ZIP, appended after the
# framework's strip), exactly like the zsh/vim ports.
#
# `static` is a target static-musl pkg set (native or cross) with staticFixes;
# `pkgs` is the build-host nixpkgs; `xkbcompObj` is the matching linux-xkbcomp.nix
# blob; `dropGL` filters the GL stack out of buildInputs.
{ static, pkgs, xkbcompObj, dropGL }:
static.xorg-server.overrideAttrs (old: {
  pname = "xvfb";
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.bison ];

  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Dxorg=false" "-Dxephyr=false" "-Dxnest=false" "-Dxvfb=true"
    "-Dglamor=false" "-Ddri3=false" "-Dglx=false" "-Dsecure-rpc=false"
    # XKB + fonts live in the embedded VFS at /zip; the server reads them via
    # fopen (routed through --wrap) and the patched RunXkbComp compiles in-process.
    "-Dxkb_dir=/zip/xkb" "-Dxkb_bin_dir=/usr/bin" "-Dxkb_output_dir=/tmp"
    "-Dsha1=libmd" "-Ddefault_font_path=/zip/fonts/misc"
  ];

  # Rewrite RunXkbComp to compile in-process (fork + unpin_xkbcomp_main), and
  # drop the test-client suite (not shipped; would inherit the global link flags
  # and break the cross static link).
  postPatch = (old.postPatch or "") + ''
    # Build-host python3 (pkgs is the TARGET set on a cross build; a shell-
    # interpolated path doesn't splice like nativeBuildInputs, so reach for
    # buildPackages explicitly or a cross build would compile python3 for the
    # target — sqlite/python cross-fail on i686-musl).
    ${pkgs.buildPackages.python3.interpreter} ${./patch-ddxload.py}
    substituteInPlace meson.build \
      --replace-fail "subdir('test')" "# subdir('test') removed (unpins: not shipped, breaks cross static link)"
  '';

  preBuild = (old.preBuild or "") + ''
    ###### unpin-vfs runtime objects (static musl $CC) ######
    $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF -DUNPIN_VFS_DIRS \
      -I${./src} -c ${./src/vfs.c} -o vfs.o
    $CC -O2 -DMINIZ_USE_ZSTD -I${./src} -c ${./src/miniz.c} -o miniz.o
    $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I${./src} \
      -c ${./src/unpin_zstd.c} -o unpin_zstd.o

    ###### wire the final Xvfb link ######
    # The xkbcomp object is fully self-contained; the server link just adds it +
    # the VFS objects. No -lxkbfile/-lX11 (would clash with the server's XKB).
    export NIX_LDFLAGS="$NIX_LDFLAGS \
      --wrap=open --wrap=stat --wrap=lstat --wrap=access \
      --wrap=fopen --wrap=opendir --wrap=readdir --wrap=closedir \
      $PWD/vfs.o $PWD/miniz.o $PWD/unpin_zstd.o \
      ${xkbcompObj}/xkbcomp_localized.o"
  '';

  # Ship the binary as `xvfb` (== package name, required by action-build's
  # name-based verify/smoke); `Xvfb` is re-added as an embedded alias. xorg=false
  # so the only bin is Xvfb (drop the dangling X → Xorg symlink if present).
  # Two-step rename via a temp name so it works on a case-insensitive FS too
  # (uniform with the darwin module; a direct mv Xvfb->xvfb is "same file" there).
  postInstall = (old.postInstall or "") + ''
    rm -f $out/bin/X
    mv $out/bin/Xvfb $out/bin/xvfb.unpin-tmp
    mv $out/bin/xvfb.unpin-tmp $out/bin/xvfb
  '';

  buildInputs = builtins.filter (x: !dropGL x) (old.buildInputs or [ ])
    ++ [ static.libmd ];
  propagatedBuildInputs =
    builtins.filter (x: !dropGL x) (old.propagatedBuildInputs or [ ]);
  meta = (old.meta or { }) // { platforms = pkgs.lib.platforms.all; };

  # The VFS objects + --wrap flags ride on the GLOBAL NIX_LDFLAGS, so they apply
  # to every link. That is only sound while Xvfb is the SOLE linked executable
  # (xvfb=true, all other DDXs=false). Assert it here (runs before withUnpinEmbed
  # appends the ZIP): a future meson bump linking a second binary would have it
  # silently inherit the wraps + VFS objects.
  postFixup = (old.postFixup or "") + ''
    elfbins=""
    for f in $(find "$out" -type f); do
      file -b "$f" | grep -q "ELF.*executable" && elfbins="$elfbins $f"
    done
    if [ "$(echo $elfbins | wc -w)" != 1 ]; then
      echo "FATAL: expected exactly 1 ELF executable in \$out, got:$elfbins" >&2
      exit 1
    fi
  '';
})
