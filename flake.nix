{
  description = "Xvfb (the virtual framebuffer X server) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";
  inputs.nixpkgs.follows = "unpins-lib/nixpkgs";

  # Xvfb (the virtual framebuffer X server) as a single self-contained binary —
  # the whole client-side xkbcomp compiled in-process (every RMLVO keymap), the
  # xkeyboard-config tree + core bitmap fonts embedded in the binary's EOF ZIP
  # and served by the unpin-vfs, no /nix/store closure.
  #
  # Three structurally different platform paths feed one mkStandaloneFlake:
  #   - Linux (static-musl, every arch): VFS via `ld --wrap`; see linux.nix.
  #   - macOS (Mach-O, libSystem-only): no --wrap → llvm-objcopy --redefine-sym
  #     + relink against a dynamic-base build with pkgsStatic libs; see darwin.nix.
  #   - Windows (Cosmopolitan APE → PE): cosmo's native zipos VFS; see cosmo/.
  # The xkb tree + core fonts are embedded by nix-lib's withUnpinEmbed
  # (runtimeStage) on Linux/macOS, and by cosmo's own zipos zip on Windows.
  outputs = { self, unpins-lib, nixpkgs }:
    let
      lib = nixpkgs.lib;

      # Arch-independent runtime data (XKB rules/symbols text + .pcf.gz bitmap
      # fonts). Pull the x86_64-linux copies so cross/darwin builders don't
      # rebuild pure data; identical bytes either way.
      dataPkgs = nixpkgs.legacyPackages."x86_64-linux";

      # pkgsStatic leaf fixes: a few libs default meson/libtool to a shared
      # object that can't link the static-only crt; force static. libfontenc
      # bakes its encodingsdir as an embedded /nix/store string → pin to /zip.
      staticFixes = selfP: superP: {
        libxcvt = superP.libxcvt.overrideAttrs (o: {
          postPatch = (o.postPatch or "") + ''
            substituteInPlace lib/meson.build \
              --replace-fail "shared_library('xcvt'," "library('xcvt',"
          '';
          mesonFlags = (o.mesonFlags or [ ]) ++ [ "-Ddefault_library=static" ];
        });
        libfontenc = superP.libfontenc.overrideAttrs (o: {
          configureFlags = (o.configureFlags or [ ]) ++ [
            "--with-fontrootdir=/zip/fonts"
            "--with-encodingsdir=/zip/fonts/encodings"
          ];
        });
      };
      # The X stack libs are marked `badPlatforms = static` (and pkgsStatic.python3
      # `broken`) in nixpkgs even though they build + link fine static (the spike
      # proved the whole Xvfb closure does). mkStandaloneFlake's pkgs doesn't set
      # the escape hatches, so re-derive the set from the SAME nixpkgs with them —
      # exactly what the spike's importCross / darwin import did. Keyed off the
      # framework-passed platform so native and every cross/darwin reproduce the
      # right (build, host) pair. (Drops the framework's LLD-link wrapper, which
      # the spike never used — a uniform-linker nicety, not a correctness need.)
      allowUnsup = pkgs:
        let hp = pkgs.stdenv.hostPlatform; bp = pkgs.stdenv.buildPlatform; in
        import nixpkgs ({
          system = bp.system;
          config = {
            allowUnsupportedSystem = true;
            allowBroken = true;
            problems.handlers.python3.broken = "ignore";
          };
        } // lib.optionalAttrs (hp != bp) { crossSystem = { config = hp.config; }; });
      # Inputs Xvfb (xvfb=true, all other DDXs=false) never uses. The GL stack is
      # dropped because we disable glamor/glx; libpciaccess/libxshmfence are
      # Xorg-DDX-only (PCI probe / DRI fence) and nixpkgs marks them
      # badPlatforms=static, so keeping them would need allowUnsupportedSystem
      # (the spike's crutch) — dropping is cleaner and shrinks the closure. The
      # cosmo path already drops the same set as "junk".
      dropGL = x:
        builtins.elem (x.pname or x.name or "")
          [ "libepoxy" "libglvnd" "glu" "mesa-libgbm" "libpciaccess" "libxshmfence" ];

      # Cosmo (Windows) leaf fixes — same intent as staticFixes, retargeted to the
      # cosmocc cross set. libxfont2 needs no FreeType backend (PCF fonts only);
      # libxcvt static; pixman drops the libpng/zlib-probing demos/tests.
      xvfbCosmoFixes = final: prev: {
        libxfont_2 = prev.libxfont_2.overrideAttrs (o: {
          configureFlags = (o.configureFlags or []) ++ [ "--disable-freetype" ];
          buildInputs = builtins.filter
            (x: (x.pname or x.name or "") != "freetype") (o.buildInputs or []);
        });
        libxcvt = prev.libxcvt.overrideAttrs (o: {
          postPatch = (o.postPatch or "") + ''
            substituteInPlace lib/meson.build \
              --replace 'shared_library(' 'library('
          '';
        });
        pixman = prev.pixman.overrideAttrs (o: {
          mesonFlags = (o.mesonFlags or []) ++ [ "-Dtests=disabled" "-Ddemos=disabled" ];
          buildInputs = builtins.filter
            (x: builtins.match ".*libpng.*" (x.name or "") == null) (o.buildInputs or []);
        });
      };

      # The xkb tree + core fonts, staged at the embedded ZIP root for the
      # unpin-vfs self-EOF reader. Shared by the Linux + macOS withUnpinEmbed
      # calls (Windows embeds the same trees via cosmo's zipos in cosmo/).
      runtimeStage = ''
        mkdir -p "$__unpin_stage/xkb" "$__unpin_stage/fonts/misc"
        # -aL: deref the rules/{xorg,xorg.lst,xorg.xml} -> base* symlinks so the
        # ZIP is symlink-free; the dupes are byte-identical → the shared zstd dict
        # erases them.
        cp -aL ${dataPkgs.xkeyboard_config}/share/X11/xkb/. "$__unpin_stage/xkb/"

        cp ${dataPkgs.xorg.fontmiscmisc}/share/fonts/X11/misc/*.pcf.gz "$__unpin_stage/fonts/misc/"
        cp ${dataPkgs.xorg.fontcursormisc}/share/fonts/X11/misc/*.pcf.gz "$__unpin_stage/fonts/misc/"
        { n1=$(sed -n 1p ${dataPkgs.xorg.fontmiscmisc}/share/fonts/X11/misc/fonts.dir)
          n2=$(sed -n 1p ${dataPkgs.xorg.fontcursormisc}/share/fonts/X11/misc/fonts.dir)
          echo $((n1 + n2))
          tail -n +2 ${dataPkgs.xorg.fontmiscmisc}/share/fonts/X11/misc/fonts.dir
          tail -n +2 ${dataPkgs.xorg.fontcursormisc}/share/fonts/X11/misc/fonts.dir
        } > "$__unpin_stage/fonts/misc/fonts.dir"
        cp ${dataPkgs.xorg.fontalias}/share/fonts/X11/misc/fonts.alias \
           "$__unpin_stage/fonts/misc/fonts.alias"
        chmod -R u+w "$__unpin_stage"
      '';

      # The bare server derivation for a target pkg set: Linux static-musl or the
      # macOS dynamic-base build (branch on the platform). Does NOT embed data or
      # strip — withUnpinEmbed (below) does that uniformly.
      buildServer = pkgs0:
        let pkgs = allowUnsup pkgs0; in
        if pkgs.stdenv.hostPlatform.isDarwin then
          let xk = import ./darwin-xkbcomp.nix { inherit pkgs; };
          in import ./darwin.nix { inherit pkgs; xkbcompObj = xk; }
        else
          let
            static = pkgs.pkgsStatic.extend staticFixes;
            xk = import ./linux-xkbcomp.nix { inherit static pkgs; };
          in import ./linux.nix { inherit static pkgs dropGL; xkbcompObj = xk; };

      # mkStandaloneFlake `build`: the PRISTINE server (no embed). The xkb/font
      # runtime tree + Xvfb alias + man are embedded once, post-build, via
      # runtimeEmbed.native → unpinEmbedWrap (one self-EOF ZIP, the single embed
      # path). The binary must be named `xvfb` (== binName): action-build looks
      # for result/bin/xvfb; the X server doesn't dispatch on its filename, so the
      # upstream `Xvfb` is renamed → `xvfb` in each module's postInstall and shipped
      # as the `Xvfb` alias. Windows is cosmo (cosmo/) which embeds xkb/fonts via
      # its own zipos in-build, so only man is added there (the framework default).
      build = pkgs: buildServer pkgs;
      runtimeEmbed.native = pkgs: base: {
        aliases = [ "Xvfb" ];
        man = true;
        inherit runtimeStage;
      };

      # Windows: the cosmo cross set with the xvfb leaf fixes layered on, feeding
      # the cosmo Xvfb module (its own zipos embed for xkb/fonts; the framework
      # then carries that tail-ZIP and adds man via withMan --carry).
      windowsBuild = wpkgs:
        let
          c = wpkgs.pkgsCross.cosmo.extend xvfbCosmoFixes;
          xk = import ./cosmo/xkbcomp.nix { cosmoPkgs = c; };
        in import ./cosmo/default.nix { cosmoPkgs = c; inherit nixpkgs; xkbcompObj = xk; };
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "xvfb";
      # nixpkgs attr for the man graft / optimize overlay. xorg-server has no
      # clean top-level attr we want optimized, and the build is bespoke, so GC
      # is off; man is harvested from the build's own share/man.
      pkgsAttr = "xorg-server";
      license = "MIT";
      optimize = { gc = false; };
      # The xserver bakes `$out/lib/xorg/protocol.txt` into the binary, but this
      # build installs only bin/ — the path never exists. Harmless as a
      # self-reference in the pristine base; once unpinEmbedWrap copies the binary
      # into its own output it becomes a real dependency on the base (measured:
      # one ref, to the base, on x86_64-linux). Scrub it.
      removeReferences = [ "xvfb" ];

      inherit build windowsBuild runtimeEmbed;

      # Xvfb is a server; `-help` prints its usage to stderr and exits 0. Pattern
      # on an Xvfb-specific option so the smoke proves it's Xvfb, not any X.
      smoke = [ "-help" ];
      smokePattern = "-fbdir";
    };
}
