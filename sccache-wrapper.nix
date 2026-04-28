let
  sccacheWrapperDrv =
    {
      sccache,
      stdenv,
      unwrappedCC,
      extraConfig,
      makeWrapper,
      lib,
    }:
    stdenv.mkDerivation {
      pname = "sccache-links";
      version = sccache.version;
      nativeBuildInputs = [ makeWrapper ];
      buildCommand =
        let
          targetPrefix =
            if unwrappedCC.isClang or false then
              ""
            else
              (lib.optionalString (unwrappedCC ? targetConfig) "${unwrappedCC.targetConfig}-");
        in
        ''
          mkdir -p $out/bin
          wrap() {
            local cname="${targetPrefix}$1"
            if [ -x "${unwrappedCC}/bin/$cname" ]; then
              makeWrapper ${sccache}/bin/sccache $out/bin/$cname \
                --run ${lib.escapeShellArg extraConfig} \
                --add-flags ${unwrappedCC}/bin/$cname
            fi
          }
          wrap cc; wrap c++; wrap gcc; wrap g++; wrap clang; wrap clang++
          # Link remaining binaries
          for bin in $(ls ${unwrappedCC}/bin); do
            if [ ! -x "$out/bin/$bin" ]; then ln -s ${unwrappedCC}/bin/$bin $out/bin/$bin; fi
          done
          # Link other files from unwrappedCC
          find ${unwrappedCC} -maxdepth 1 -not -name bin -not -name . -exec ln -s {} $out/ \;
        '';
    };

  sccacheOverlay = self: super: {
    # 1. Wrapper for C/C++
    sccacheWrapper =
      super.lib.makeOverridable
        (
          { extraConfig, cc }:
          cc.override {
            cc = self.callPackage sccacheWrapperDrv {
              # Pass SCCACHE_DIR to the C wrapper as well
              extraConfig = extraConfig + ''
                export SCCACHE_DIR=/var/cache/sccache
                export SCCACHE_NO_DAEMON=1
              '';
              unwrappedCC = cc.cc;
            };
          }
        )
        {
          extraConfig = "";
          inherit (super.stdenv) cc;
        };

    # 2. Recursive BuildRustPackage Override
    rustPlatform = super.rustPlatform // {
      buildRustPackage =
        args:
        let
          # We call the original buildRustPackage first.
          drv = super.rustPlatform.buildRustPackage args;
          pname = drv.pname or "";

          isTarget = super.lib.strings.hasPrefix "ironcalc" pname;

          sccachePkg = super.sccache;
        in
        if isTarget then
          drv.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ sccachePkg ];
            RUSTC_WRAPPER = "${sccachePkg}/bin/sccache";
            SCCACHE_DIR = "/var/cache/sccache";
            SCCACHE_LOG = "debug";
            # Disable daemon to avoid permission issues with nixbld users and sockets
            SCCACHE_NO_DAEMON = 1;
            # Ensure a writable HOME for sccache metadata
            HOME = "/tmp";
            # Disable purity checks so sccache can link things from the host cache
            NIX_ENFORCE_PURITY = 0;
          })
        else
          drv;
    };

    # 3. Global sccacheStdenv
    sccacheStdenv = super.lib.lowPrio (
      super.lib.makeOverridable (
        { stdenv, ... }@extraArgs:
        super.overrideCC stdenv (
          self.sccacheWrapper.override {
            inherit (stdenv) cc;
            extraConfig = extraArgs.extraConfig or "";
          }
        )
      ) { inherit (super) stdenv; }
    );
  };
in
{
  pkgs ? import <nixpkgs> {
    config = { };
    overlays = [ sccacheOverlay ];
  },
  ...
}:
pkgs
