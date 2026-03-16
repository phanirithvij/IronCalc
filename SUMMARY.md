# IronCalc Nix Packaging Summary

Packaging IronCalc for Nix involved coordinating several distinct components: a Rust-based core, WASM bindings, a React frontend, and a Rocket-based server.

## Key Components

### 1. WASM Bindings (`ironcalc-wasm`)
- **Version Matching:** The `wasm-bindgen-cli` version used in the build must exactly match the version of `wasm-bindgen` in `Cargo.lock`. We used `wasm-bindgen-cli_0_2_108`.
- **Package Metadata:** `wasm-pack` usually generates a `package.json`. In Nix, we manually created one to ensure it had the correct `exports`, `type: "module"`, and `types` fields for the frontend build.
- **Dependencies:** Requires `lld` for linking, `python3` for post-processing scripts, and `typescript` for type generation.

### 2. Frontend (`ironcalc-frontend`)
- **Multi-directory Build:** The frontend depends on local packages (`@ironcalc/workbook` and `@ironcalc/wasm`). In a Nix `buildNpmPackage` environment, these must be manually placed into `node_modules` or symlinked because the npm fetcher cannot follow relative paths outside the `sourceRoot`.
- **Lockfile Issues:** Fixed "missing resolved URLs" in `package-lock.json` by regenerating it locally. Used `npmDepsFetcherVersion = 2` to handle modern lockfile formats.
- **React 19 Compatibility:** Fixed a TypeScript error where `onInput` on a styled component didn't match the expected type by substituting it with `onChange`.

### 3. Server (`ironcalc-server`)
- **Source Root:** Built from the `webapp/app.ironcalc.com/server` subdirectory.
- **Cargo Update:** Encountered issues with ambiguous package specifications (e.g., `atomic`) when trying to update dependencies in `postPatch`.

### 4. Integration Wrapper (`ironcalc-web`)
- **Caddy:** Used `caddy` to serve the static frontend and reverse proxy `/api/*` requests to the Rocket server (running on port 8000).
- **Service Orchestration:** A simple shell script manages starting both the server and the proxy.

## Pitfalls & Learnings

- **`buildNpmPackage` fetcher vs builder:** Any patches that affect dependency resolution must be applied in the fetcher phase. However, `substituteInPlace` can fail in the fetcher if the pattern isn't found exactly, so `sed -i ... || true` is safer for optional or context-dependent patches.
- **Relative Paths in npm:** `npm install` with local `file:` dependencies is very fragile in Nix. Copying the dependency directly into `node_modules/@scope/pkg` in the `buildPhase` is often more reliable than relying on npm's resolution of relative paths.
- **Permissions:** Unpacked sources in Nix are read-only. `chmod -R u+w` is necessary before modifying files or creating new directories in the build tree.
- **`lib.cleanSource`:** While good for local testing, it's generally avoided for final Nixpkgs submissions in favor of `fetchFromGitHub` or similar fixed-output fetchers.

## Important Commands & Workflows

### 1. Updating `package-lock.json`
If the lockfile is missing URLs or out of sync, regenerate it from within the component directory:
```bash
# Example for frontend
cd webapp/app.ironcalc.com/frontend
rm package-lock.json
nix-shell -p nodejs --run "npm install --package-lock-only"
```

### 2. Patching Cargo Dependencies
When a dependency is unreachable or needs a specific version, use `cargo update`:
```bash
# In the server directory
nix-shell -p cargo --run "cargo update -p atomic --precise 0.6.1"
```
*Note: If building from a fixed source (like `fetchFromGitHub`), you may need to apply these updates in `postPatch` with `cargoHash` recalculated.*

### 3. Calculating Hashes
```bash
# For Cargo
nix-build -E 'with import <nixpkgs> {}; callPackage ./default.nix {}'
# For NPM
nix-build -A frontend -E 'with import <nixpkgs> {}; callPackage ./default.nix {}'
```
*Replace the hash with `lib.fakeHash` first to trigger a mismatch error containing the correct hash.*

### 4. Running the Web Stack
```bash
nix-build -E 'with import <nixpkgs> {}; (callPackage ./default.nix {}).passthru.wrapper'
./result/bin/ironcalc-web
```
*This starts the Rocket server and Caddy proxy.*

