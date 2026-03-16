{
  lib,
  rustPlatform,
  fetchFromGitHub,
  buildNpmPackage,
  python3,
  pkg-config,
  binaryen,
  bzip2,
  zstd,
  caddy,
  esbuild,
  writeShellScriptBin,
  wasm-bindgen-cli_0_2_108,
  wasm-pack,
  nodejs,
  sqlite,
  typescript,
  lld,
  writableTmpDirAsHomeHook,
}:

let
  version = "0.7.1-unstable-2026-04-25";
  src = fetchFromGitHub {
    owner = "ironcalc";
    repo = "ironcalc";
    rev = "f60171a2f07715e4754477b9b2a3ee9e5659ec87";
    hash = "sha256-eOvu+2AUNW2USGcnZQ73g5ofNMFJ3drwA7MIsVk41xA=";
  };

  cargoHash = "sha256-q5DnqhIYKUUqfJ4/TNHYF1QgTbH198QtgirQ+lP30wk=";

  wasm = rustPlatform.buildRustPackage {
    pname = "ironcalc-wasm";
    inherit version src cargoHash;

    nativeBuildInputs = [
      binaryen
      pkg-config
      python3
      wasm-bindgen-cli_0_2_108
      wasm-pack
      nodejs
      typescript
      lld
      writableTmpDirAsHomeHook
    ];

    buildInputs = [
      bzip2
      zstd
    ];

    buildPhase = ''
      cd bindings/wasm
      make tests

      wasm-pack build --target web --scope ironcalc --release
      cp README.pkg.md pkg/README.md
      tsc types.ts --target esnext --module esnext
      python3 fix_types.py
      rm -f types.js

      # wasm-pack generates a package.json, we must provide one
      cat > pkg/package.json <<EOF
      {
        "name": "@ironcalc/wasm",
        "version": "${version}",
        "type": "module",
        "files": [
          "wasm_bg.wasm",
          "wasm.js",
          "wasm.d.ts"
        ],
        "main": "wasm.js",
        "module": "wasm.js",
        "types": "wasm.d.ts",
        "exports": {
          ".": {
            "types": "./wasm.d.ts",
            "import": "./wasm.js"
          }
        },
        "sideEffects": false
      }
      EOF
    '';

    doCheck = true;

    installPhase = ''
      cp -r pkg $out
    '';
  };

  workbook = buildNpmPackage {
    pname = "ironcalc-workbook";
    inherit version src;
    sourceRoot = "source/webapp/IronCalc";
    npmDepsHash = "sha256-jPnUUEOjW9WHVjpBH/qKB4P5RuMI0uvjog8C41cPQdY=";

    postPatch = ''
      chmod -R u+w ../../..
      mkdir -p ../../bindings/wasm/pkg
      echo '{"name": "@ironcalc/wasm", "version": "${version}"}' > ../../bindings/wasm/pkg/package.json
      cp ${./webapp/IronCalc/package-lock.json} package-lock.json
    '';

    preConfigure = ''
      cp -rv ${wasm}/. ../../bindings/wasm/pkg/
    '';

    buildPhase = ''
      npm run build
    '';

    installPhase = ''
      mkdir -p $out
      cp -r . $out
    '';
  };

  frontend = buildNpmPackage {
    pname = "ironcalc-frontend";
    inherit version src;
    sourceRoot = "source/webapp/app.ironcalc.com/frontend";
    npmDepsHash = "sha256-QVpUV3dxaqiWCF8RC1MR2ylYC500Lbp5pJgzzOrF20c=";

    postPatch = ''
      chmod -R u+w ../../..

      # wasm location fix
      mkdir -p ../../../bindings/wasm/pkg
      cp -rv ${wasm}/. ../../../bindings/wasm/pkg/

      rm -rf ../../IronCalc
      cp -r ${workbook} ../../IronCalc
      chmod -R u+w ../../IronCalc

      cp ${./webapp/app.ironcalc.com/frontend/package-lock.json} package-lock.json
    '';

    preBuild = ''
      # wasm resolution fix
      mkdir -p node_modules/@ironcalc
      cp -rv ${wasm}/. node_modules/@ironcalc/wasm
    '';

    installPhase = ''
      mkdir -p $out
      cp -r dist/. $out
    '';
  };

  server = rustPlatform.buildRustPackage {
    pname = "ironcalc-server";
    inherit version src;
    sourceRoot = "source/webapp/app.ironcalc.com/server";

    cargoLock.lockFile = ./webapp/app.ironcalc.com/server/Cargo.lock;

    postPatch = ''
      cp ${./webapp/app.ironcalc.com/server/Cargo.lock} Cargo.lock
    '';

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      bzip2
      zstd
    ];
  };

  # TODO this wrapper business is weird
  # ${lib.getExe sqlite} ironcalc.sqlite <${src}/webapp/app.ironcalc.com/server/init_db.sql
  wrapper = writeShellScriptBin "ironcalc-web" ''
    set -euo pipefail

    cat > Rocket.toml <<EOF
    [default.databases.ironcalc]
    url = "ironcalc.sqlite"
    EOF

    # existing caddyfiles in the repo are not production ready
    cat > Caddyfile <<EOF
    :2080 {
    	route {
    		reverse_proxy /api* localhost:8000
    		file_server browse {
    		  root ${frontend}
    		}
    	}
    }
    EOF

    echo "Starting IronCalc Server"
    ${lib.getExe sqlite} ironcalc.sqlite <${./webapp/app.ironcalc.com/server/init_db.sql}
    ${server}/bin/ironcalc_server &
    SERVER_PID=\$!

    echo "Starting Web UI on http://localhost:2080"
    ${caddy}/bin/caddy run --config Caddyfile

    kill "$SERVER_PID"
  '';

  ironcalc = rustPlatform.buildRustPackage (finalAttrs: {
    pname = "ironcalc";
    inherit version src cargoHash;

    patches = [ ./0001-fix-test-message.patch ];

    nativeBuildInputs = [
      pkg-config
      python3
    ];

    buildInputs = [
      bzip2
      zstd
    ];

    postInstall = ''
      cp ${wrapper}/bin/ironcalc-web $out/bin/
    '';

    passthru = {
      inherit
        wasm
        workbook
        frontend
        server
        wrapper
        ;
    };

    meta = {
      description = "Open source selfhosted spreadsheet engine";
      homepage = "https://github.com/ironcalc/IronCalc";
      license = with lib.licenses; [
        asl20
        mit
      ];
      mainProgram = "ironcalc";
      maintainers = with lib.maintainers; [ phanirithvij ];
      teams = with lib.teams; [ ngi ];
    };
  });
in
ironcalc
