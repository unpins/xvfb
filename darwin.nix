# Darwin (macOS) Xvfb server derivation — self-contained, libSystem-only Mach-O.
# NOT pure pkgsStatic (meson's pkgsStatic.python3 interpreter can't statically
# link on macOS); build with the DYNAMIC darwin stdenv but swap the LINKED libs
# to their pkgsStatic .a variants. The COMPILER is the engine (unpin-llvm) all
# the same: the adapter stdenv only replaces the cc, so the dynamic link model
# macOS forces on us is untouched while the server's own code goes through the
# engine like every other target.
#
# -flto makes those objects LLVM bitcode, which decides the VFS back-end per
# input. vfs.c's __APPLE__ branch defines unpinvfs_* either way; what differs is
# how a consumer's _open/_fopen/... are pointed at them:
#   - the server's own archives are bitcode -> the IR rename (ulib.vfsBindFns).
#   - libXfont2.a and the xkbcomp blob come from OFF-engine derivations and are
#     native Mach-O -> llvm-objcopy --redefine-syms (ulib.vfsBindMap).
# Both back-ends read the same spelling table in nix-lib, so they cannot drift.
# vfs.o/miniz.o/unpin_zstd.o are NEVER rewritten (they implement the real
# syscalls).
#
# Like linux.nix this produces ONLY the server drv (no data embed / no manual
# strip) — the flake delegates the /zip embed to withUnpinEmbed (one self-EOF
# ZIP appended after the framework's strip; the bytes lie beyond codesign's
# codeLimit, matching the zsh/vim darwin ports).
#
# `pkgs` is the native OR cross darwin pkg set the framework passes (x86_64- or
# aarch64-darwin, native on its own runner or cross from the other); `xkbcompObj`
# is the matching darwin-xkbcomp.nix blob. Build-host tools come from
# pkgs.buildPackages so cross-darwin uses an executable toolchain.
{ ulib, pkgs, xkbcompObj }:
let
  static = pkgs.pkgsStatic;
  bpkgs = pkgs.buildPackages;
  llvm = bpkgs.llvm;
  multitool = ulib.llvmMultitool pkgs.stdenv.buildPlatform.system;

  # The engine cc over the dynamic darwin stdenv. `hostPkgs = pkgs` is the whole
  # point: engineStdenv's default wraps pkgsStatic, and on darwin pkgsStatic
  # collapses buildPackages into itself (build config == host config), so meson
  # would want a static python3 — the reason this module never went through
  # pkgsStatic. Wrapping the dynamic set keeps the link model and swaps only the
  # compiler.
  engStdenv = ulib.unpinAdapterStdenv {
    inherit pkgs;
    hostPkgs = pkgs;
    target = pkgs.stdenv.hostPlatform.config;
    native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
    lto = true;
    captureLinks = true;
  };

  libxfont2NoFt = static.libxfont_2.overrideAttrs (o: {
    configureFlags = (o.configureFlags or []) ++ [ "--disable-freetype" ];
    buildInputs = builtins.filter
      (x: (x.pname or x.name or "") != "freetype") (o.buildInputs or []);
  });

  nullArgs = [ "libGL" "libGLU" "libdrm" "libepoxy" "mesa" "mesa-gl-headers"
               "dbus" "udev" "dri-pkgconfig-stub" "libxfont_1" ];
  staticArgs = [ "pixman" "libxcb" "libxcb-image" "libxcb-keysyms"
                 "libxcb-render-util" "libxcb-util" "libxcb-wm"
                 "libxcvt" "libxkbfile" "libxau" "libxdmcp" ];
  overrides =
    (builtins.listToAttrs (map (n: { name = n; value = null; }) nullArgs))
    // (builtins.listToAttrs (map (n: { name = n; value = static.${n}; }) staticArgs))
    // { libxfont_2 = libxfont2NoFt; };

  # The redefine map, generated from nix-lib's ONE spelling table (lib.vfsBindMap)
  # — the same table the engine's IR rename reads, so the two back-ends can never
  # drift apart. On x86_64-darwin the stat/dir family carries the $INODE64
  # asm-label suffix and arm64-darwin uses the PLAIN forms; both are emitted
  # (objcopy ignores absent ones). Do NOT add _DARWIN_C_SOURCE anywhere — it makes
  # stdio emit _fopen$DARWIN_EXTSN, which this map (and the server objects) would
  # then miss -> VFS bypassed.
  # One list, both back-ends: what the server may reach the filesystem through.
  vfsSyms = [ "open" "stat" "lstat" "access" "fopen" "opendir" "readdir" "closedir" ];
  redefMap = pkgs.writeText "vfs-redef.map" (ulib.vfsBindMap { syms = vfsSyms; });
in
(pkgs.xorg-server.override (overrides // { stdenv = engStdenv; })).overrideAttrs (old: {
  pname = "xvfb";
  nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ llvm ];

  mesonFlags = (old.mesonFlags or []) ++ [
    "-Dxorg=false" "-Dxephyr=false" "-Dxnest=false" "-Dxvfb=true" "-Dxquartz=false"
    "-Dxwin=false" "-Dglamor=false" "-Ddri3=false" "-Dglx=false"
    "-Dsystemd_logind=false" "-Dsecure-rpc=false" "-Dsha1=libmd"
    "-Dxkb_dir=/zip/xkb" "-Dxkb_bin_dir=/usr/bin" "-Dxkb_output_dir=/tmp"
    "-Ddefault_font_path=/zip/fonts/misc"
    # nixpkgs turns the SECURITY extension on for every host except darwin,
    # with no reason given, and this list extends theirs — so the macOS server
    # was the only one without it (21 extensions against Linux's 22).
    "-Dxcsecurity=true"
  ];

  postPatch = (old.postPatch or "") + ''
    # In-process xkbcomp via mkstemp+fork+fmemopen (the cosmo variant is right for
    # macOS too: darwin has fork/mkstemp/fmemopen). Build-host python3.
    ${bpkgs.python3.interpreter} ${./cosmo/patch-ddxload-cosmo.py}
    substituteInPlace meson.build \
      --replace-fail "subdir('test')" "# subdir('test') removed (unpins: not shipped)"
  '';

  # Ship the binary as `xvfb` (== package name, required by action-build's
  # name-based verify/smoke); `Xvfb` is re-added as an embedded alias. The
  # postBuild relink targets hw/vfb/Xvfb in the build dir (unchanged); this only
  # renames the installed copy.
  # Two-step rename via a temp name: macOS's default FS is CASE-INSENSITIVE, so a
  # direct `mv Xvfb xvfb` is "same file" and errors. The temp differs in more than
  # case, so it works on both case-insensitive (darwin) and case-sensitive (linux).
  postInstall = (old.postInstall or "") + ''
    rm -f $out/bin/X
    mv $out/bin/Xvfb $out/bin/xvfb.unpin-tmp
    mv $out/bin/xvfb.unpin-tmp $out/bin/xvfb
  '';

  # Drop bootstrap_cmds from the HOST inputs: xorg-server lists it for Xquartz's
  # mig stubs (xquartz=false → dead), and on the arm64 cross it drags an arm64
  # meson → arm64 python3, which CPython's configure refuses to cross-build.
  buildInputs = (builtins.filter
    (x: (x.pname or x.name or "") != "bootstrap_cmds") (old.buildInputs or []))
    ++ [ static.libmd static.libfontenc static.zlib ];

  preBuild = (old.preBuild or "") + ''
    ###### unpin-vfs runtime objects (darwin $CC; NEVER redefined) ######
    # -DNDEBUG: miniz's MZ_ASSERT is plain assert(); clang keeps its __FILE__
    # cstring = miniz.o's store-path in .rodata (survives strip → a foreign
    # runtime ref). NDEBUG removes the assert. (gcc -O2 elides it on Linux, which
    # is why the Linux build is ref-clean without NDEBUG.)
    vfsdir=$NIX_BUILD_TOP/vfsobj
    mkdir -p $vfsdir
    $CC -O2 -DNDEBUG -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF -DUNPIN_VFS_DIRS \
      -I${ulib.vfsCore} -c ${ulib.vfsCore}/vfs.c -o $vfsdir/vfs.o
    $CC -O2 -DNDEBUG -DMINIZ_USE_ZSTD -I${ulib.vfsCore} -c ${ulib.vfsCore}/miniz.c -o $vfsdir/miniz.o
    $CC -O2 -DNDEBUG -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I${ulib.vfsCore} \
      -c ${ulib.vfsCore}/unpin_zstd.c -o $vfsdir/unpin_zstd.o

    ###### VFS-localized copies of the external font lib + the xkbcomp blob ######
    cp ${libxfont2NoFt}/lib/libXfont2.a $vfsdir/libXfont2_vfs.a
    chmod +w $vfsdir/libXfont2_vfs.a
    llvm-objcopy --redefine-syms=${redefMap} $vfsdir/libXfont2_vfs.a
    cp ${xkbcompObj}/xkbcomp_localized.o $vfsdir/blob_vfs.o
    llvm-objcopy --redefine-syms=${redefMap} $vfsdir/blob_vfs.o

    ###### wire the link ######
    # NIX_CFLAGS_LINK, not NIX_LDFLAGS: the cc wrapper `-Wl,`-prefixes every
    # NIX_LDFLAGS token that does not start with `-L/`, and the engine clang does
    # not lower `-Wl,<path>` — it hands the token to ld64.lld whole, which then
    # reports "cannot open …/-Wl,/nix/store/…/vfs.o". NIX_CFLAGS_LINK is added
    # raw, which is where an object path belongs anyway.
    export NIX_CFLAGS_LINK="''${NIX_CFLAGS_LINK:-} \
      $vfsdir/vfs.o $vfsdir/miniz.o $vfsdir/unpin_zstd.o $vfsdir/blob_vfs.o \
      -L${static.libfontenc}/lib -lfontenc -L${static.zlib}/lib -lz"
  '';

  postBuild = (old.postBuild or "") + ''
    ###### localize file I/O in the server archives, then relink Xvfb ######
    vfsdir=$NIX_BUILD_TOP/vfsobj
    MT=${multitool}
    ${ulib.vfsBindFns { syms = vfsSyms; }}
    ${ulib.vfsBindArchiveFns}
    echo "=== renaming file I/O in server archives (IR) ==="
    # The server's convenience archives are bitcode now, so `objcopy
    # --redefine-syms` has no symtab to touch and would report them as not a
    # valid object file. Rewrite the IR instead — same rename, same table.
    find . -name '*.a' -print | while read -r a; do bcrewriteArchive "$a"; done

    # Replay the captured Xvfb link with libXfont2_vfs.a injected BEFORE the store
    # -lXfont2 (ld64: first archive defining a symbol wins). vfs/blob ride on
    # NIX_CFLAGS_LINK (re-read by the cc-wrapper on replay).
    linkcmd=$(ninja -t commands hw/vfb/Xvfb | tail -1)
    if [ -z "$linkcmd" ]; then echo "FATAL: no link command for hw/vfb/Xvfb" >&2; exit 1; fi
    newcmd=$(printf '%s' "$linkcmd" | sed \
      "s#-o hw/vfb/Xvfb#-o hw/vfb/Xvfb $vfsdir/libXfont2_vfs.a#")
    echo "=== relinking Xvfb with VFS objects ==="
    eval "$newcmd"

    # llvm-objdump, not `otool`: the engine stdenv drops cctools (apple-sdk is
    # nulled so the wrapper cannot re-inject ld64), so `otool` is not on PATH and
    # the gate below read an EMPTY list and passed on nothing. --macho
    # --dylibs-used prints otool -L's format from the llvm already listed in
    # nativeBuildInputs, which is present on the native and the cross builder
    # alike.
    echo "=== dylibs used by hw/vfb/Xvfb ==="
    llvm-objdump --macho --dylibs-used hw/vfb/Xvfb
    bad=$(llvm-objdump --macho --dylibs-used hw/vfb/Xvfb | tail -n +2 \
          | awk '{print $1}' \
          | grep -vE '^/usr/lib/libSystem|^/System/Library' || true)
    if [ -n "$bad" ]; then
      echo "FATAL: Xvfb links non-libSystem dylibs:" >&2; echo "$bad" >&2; exit 1
    fi
    # llvm-nm (cross stdenv has no bare nm on PATH; llvm-nm reads any arch).
    if llvm-nm hw/vfb/Xvfb | grep -qw _unpinvfs_open; then
      echo "VFS shims linked in: $(llvm-nm hw/vfb/Xvfb | grep -c _unpinvfs_)"
    else
      echo "FATAL: _unpinvfs_open not in the final image (relink lost the VFS)" >&2
      llvm-nm hw/vfb/Xvfb | grep -i unpinvfs || true
      exit 1
    fi
  '';

  meta = (old.meta or {}) // { platforms = pkgs.lib.platforms.all; };
})
