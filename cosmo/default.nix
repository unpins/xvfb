# Cosmopolitan (Windows) Xvfb — the spike's static X server built as an APE and
# apelinked to a Windows PE (Xvfb.exe). Functionally verified on a real Windows
# VM: X11 handshake + request dispatch + in-process xkbcomp keymap compile.
#
# Structural differences from the Linux mkXvfb (see ../flake.nix):
#   * VFS = cosmo's NATIVE zipos. fopen("/zip/..") is served from the APE's
#     embedded zip section by cosmo's libc, so the whole --wrap/vfs.c/miniz
#     machinery is GONE here; embedding is a plain `zip -r -9 Xvfb.exe ...`.
#   * Three cosmo-on-Windows runtime fixes baked in below: -DUSE_POLL,
#     XTRANS_SEND_FDS=false, and the mkstemp+fork+fmemopen RunXkbComp variant.
{ cosmoPkgs, nixpkgs, xkbcompObj }:
let
  c = cosmoPkgs;
  # Native nixpkgs for build-host tools (python3, zip) and the ARCH-INDEPENDENT
  # data trees (xkeyboard-config, core fonts) -- text/bitmap data, not cosmo
  # objects, so the native build is correct and avoids a cosmo rebuild.
  np = nixpkgs.legacyPackages."x86_64-linux";

  xkbTree = np.xkeyboard_config;
  fontMisc = np.xorg.fontmiscmisc;
  fontCursor = np.xorg.fontcursormisc;
  fontAlias = np.xorg.fontalias;

  junk = [ "libdrm" "mesa-libgbm" "mesa-gl-headers" "dri-pkgconfig-stub"
           "libepoxy" "libglvnd" "glu" "libpciaccess" "libxshmfence"
           "dbus" "libunwind" "libxfont_1" "openssl" "font-util" ];
  dropJunk = inputs: builtins.filter
    (x: !(builtins.elem (x.pname or x.name or "") junk)) inputs;
  stripFlags = pfx: fs: builtins.filter
    (f: !(builtins.any (p: builtins.match ("-D" + p + "=.*") f != null) pfx)) fs;
in
c.xorg-server.overrideAttrs (o: {
  pname = "xvfb-cosmo";
  nativeBuildInputs = (o.nativeBuildInputs or []) ++ [ np.python3 np.zip ];
  buildInputs = dropJunk (o.buildInputs or []) ++ [ c.libmd ];
  propagatedBuildInputs = dropJunk (o.propagatedBuildInputs or []);

  env = (o.env or {}) // {
    NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " [
      (o.env.NIX_CFLAGS_COMPILE or "")
      "-Wno-implicit-function-declaration"
      # cosmo's sysconf(_SC_OPEN_MAX) returns -1 on Windows -> Xtranssock.c's
      # (X11_t && !USE_POLL) guard `fd >= sysconf(...)` is `3 >= -1` == true and
      # closes every listen socket right after socket(). USE_POLL gates ONLY that
      # guard in all of xtrans; the server multiplexes via os/ospoll.
      "-DUSE_POLL"
    ];
    NIX_LDFLAGS = builtins.concatStringsSep " " [
      (o.env.NIX_LDFLAGS or "")
      # Static single-pass link: leaf libs referenced by earlier archives
      # (libXfont2->z, libxcb->Xau/Xdmcp) must be re-listed at the end.
      "-L${c.zlib.static}/lib" "-lz"
      "-L${c.xorg.libXau}/lib" "-lXau"
      "-L${c.xorg.libXdmcp}/lib" "-lXdmcp"
      # The self-contained in-process xkbcomp blob (exports only
      # unpin_xkbcomp_main; depends on nothing but libc).
      "${xkbcompObj}/xkbcomp_localized.o"
    ];
  };

  mesonFlags = (stripFlags [ "xkb_bin_dir" "xkb_dir" "xkb_output_dir" "default_font_path" ] (o.mesonFlags or [])) ++ [
    "-Dxorg=false" "-Dxephyr=false" "-Dxnest=false" "-Dxvfb=true"
    "-Dxwin=false" "-Dxquartz=false"
    "-Dglamor=false" "-Ddri3=false" "-Dglx=false" "-Ddocs=false"
    "-Dsystemd_logind=false" "-Dsecure-rpc=false" "-Dsha1=libmd"
    # XKB + fonts live in the APE's native zipos at /zip/...; the server's
    # fopen/open resolve there transparently (no --wrap needed on cosmo).
    "-Dxkb_dir=/zip/xkb" "-Dxkb_bin_dir=/usr/bin" "-Dxkb_output_dir=/tmp"
    "-Ddefault_font_path=/zip/fonts/misc"
  ];

  # Rewrite RunXkbComp -> in-process fork + unpin_xkbcomp_main (cosmo variant:
  # mkstemp temp files + fmemopen handoff, no memfd, no unlink-while-open).
  postPatch = (o.postPatch or "") + ''
    ${np.python3.interpreter} ${./patch-ddxload-cosmo.py}

    # Drop the test-client suite for the same reason as the Linux build (not
    # shipped; would inherit this build's link flags). subdir('test') is gated
    # on non-Windows in meson.build, and cosmo presents as non-Windows at build
    # time, so it would otherwise build.
    substituteInPlace meson.build \
      --replace-fail "subdir('test')" "# subdir('test') removed (unpins: not shipped)"

    # cosmo headers expose SCM_RIGHTS, so meson enables XTRANS_SEND_FDS and the
    # transport's SocketRead/Writev use recvmsg/sendmsg with an SCM_RIGHTS
    # control buffer. On Windows that recvmsg returns -1/WSAEINVAL, so the server
    # fails the very first read of a client's connection-setup and drops it.
    # Xvfb needs no fd-passing (DRI3 off); disable it so SocketRead falls back to
    # plain read()/writev(), which work on cosmo.
    # --replace-fail: this edit is load-bearing for Windows correctness (a silent
    # no-op would leave XTRANS_SEND_FDS on -> recvmsg/SCM_RIGHTS -> the server
    # drops every client's connection-setup read on cosmo). Fail loudly on drift.
    substituteInPlace include/meson.build \
      --replace-fail "conf_data.set('XTRANS_SEND_FDS', '1')" \
                     "conf_data.set('XTRANS_SEND_FDS', false)"
  '';

  # Ship the binary as `xvfb` (== package name, required by action-build's
  # name-based verify/smoke). Rename BEFORE preFixup so apelinkHook turns
  # bin/xvfb into bin/xvfb.exe.
  postInstall = (o.postInstall or "") + ''
    rm -f $out/bin/X
    mv $out/bin/Xvfb $out/bin/xvfb.unpin-tmp
    mv $out/bin/xvfb.unpin-tmp $out/bin/xvfb
  '';

  # apelinkHook (preFixup) renames xvfb -> xvfb.exe. We must embed the /zip data
  # AFTER that, in postFixup, so the appended zip rides on the final .exe. The
  # binary isn't stripped (apelink needs .symtab; dontStrip via the hook).
  postFixup = (o.postFixup or "") + ''
    bin=$out/bin/xvfb.exe
    [ -f "$bin" ] || { echo "FATAL: $bin not found (apelink failed?)" >&2; exit 1; }

    stage=$(mktemp -d)
    mkdir -p $stage/xkb $stage/fonts/misc
    # -aL: deref the rules/{xorg,xorg.lst,xorg.xml} -> base* symlinks so the zip
    # is symlink-free (cosmo zipos resolution stays simple).
    cp -aL ${xkbTree}/share/X11/xkb/. $stage/xkb/

    cp ${fontMisc}/share/fonts/X11/misc/*.pcf.gz $stage/fonts/misc/
    cp ${fontCursor}/share/fonts/X11/misc/*.pcf.gz $stage/fonts/misc/
    { n1=$(sed -n 1p ${fontMisc}/share/fonts/X11/misc/fonts.dir)
      n2=$(sed -n 1p ${fontCursor}/share/fonts/X11/misc/fonts.dir)
      echo $((n1 + n2))
      tail -n +2 ${fontMisc}/share/fonts/X11/misc/fonts.dir
      tail -n +2 ${fontCursor}/share/fonts/X11/misc/fonts.dir
    } > $stage/fonts/misc/fonts.dir
    cp ${fontAlias}/share/fonts/X11/misc/fonts.alias $stage/fonts/misc/fonts.alias
    chmod -R u+w $stage

    # Append into the APE's zip section (cosmo serves the members at /zip/...).
    # InfoZIP preserves the non-zip PE/ELF prefix (SFX convention) and rewrites
    # the central directory at EOF, where cosmo's zipos scans for it.
    ( cd $stage && zip -q -r -9 "$bin" xkb fonts )
    echo "embedded /zip xkb tree + core fonts; Xvfb.exe now $(stat -c %s "$bin") bytes"
  '';

  dontStrip = true;
  meta = (o.meta or {}) // { platforms = np.lib.platforms.all; };
})
