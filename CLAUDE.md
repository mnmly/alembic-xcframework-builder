# CLAUDE.md — alembic-xcframework-builder

## Purpose

Standalone tool that builds an `Alembic.xcframework` for macOS (arm64) from any tagged upstream Alembic release. Lives **outside** the Alembic source tree. Sibling project to `gdal-xcframework-builder` and `pdal-xcframework-builder`.

## Why a builder is needed

Alembic's CMake (`ALEMBIC_SHARED_LIBS=ON`) produces a regular `libAlembic.<version>.dylib` plus headers under `include/Alembic/...`. It does not emit a macOS `.framework`. This builder does a normal install, then assembles the framework structure in shell — same approach as the PDAL builder, but simpler (no plugins, no proj.db, no GDAL).

## Pipeline (build.sh, 8 phases)

1. **Fetch** — clone upstream Alembic at tag (auto-detects `<version>` or `v<version>` via `git ls-remote`; override with `ALEMBIC_TAG`).
2. **Configure** — `ALEMBIC_SHARED_LIBS=ON`, `USE_BINARIES=OFF`, `USE_TESTS=OFF`, `USE_EXAMPLES=OFF`, `USE_HDF5=${USE_HDF5}` (default `OFF`), `Imath_DIR=${IMATH_PREFIX}/lib/cmake/Imath`, `CMAKE_FIND_FRAMEWORK=LAST`.
3. **Build + install** into `work/.../install` (`lib/libAlembic.X.Y.Z.dylib`, `include/Alembic/...`).
4. **Assemble framework** at `work/.../stage/Alembic.framework`:
   - `Versions/A/Alembic` ← `lib/libAlembic.X.Y.Z.dylib`, with `install_name_tool -id "@rpath/Alembic.framework/Versions/A/Alembic"`
   - SOVERSION-derived symlinks `libAlembic.<X>.dylib`, `libAlembic.dylib` → `Alembic`
   - `Versions/A/Headers/Alembic/` ← `install/include/Alembic/` (preserves nested layout)
   - `Versions/A/Modules/module.modulemap` ← shipped at `resources/module.modulemap`
   - `Versions/A/Resources/Info.plist` written via heredoc (same approach as PDAL builder, avoids smart-quote issues)
5. **Bundle deps + rpath fixup** — `dylibbundler` pulls in Imath (and any optional HDF5/zlib if enabled), then dedupe LC_RPATHs and rewrite `@loader_path/Libraries/<name>` → `@loader_path/<name>` inside bundled dylibs.
6. **Top-level symlinks** — `Alembic`, `Headers`, `Modules`, `Libraries`, `Resources` → `Versions/Current/...`; `Versions/Current → A`.
7. **Codesign (optional)** — only if `CODESIGN_IDENTITY` set. Usually unnecessary; Xcode re-signs on Embed & Sign.
8. **xcframework + zip** — `xcodebuild -create-xcframework`, `ditto` zip, `swift package compute-checksum`. Optional `gh release create` if `RELEASE=1` and `GH_RELEASE_REPO` set.

## Files

- `build.sh` — orchestrator
- `resources/module.modulemap` — bundled into the framework's `Modules/`. Edit to change Swift import surface.
- `Makefile` — `xcframework`, `release`, `clean`, `distclean`
- `config.sh.example` — template (user copies to `config.sh`, gitignored)
- `work/`, `output/` — gitignored

## Config knobs (config.sh)

- `IMATH_PREFIX` (default `brew --prefix imath`)
- `USE_HDF5` (default `OFF`)
- `CODESIGN_IDENTITY` (optional)
- `OUTPUT_DIR` (default `./output`)
- `SWIFT_PACKAGE_FRAMEWORKS_DIR` (optional mirror dest)
- `GH_RELEASE_REPO` (for `make release`)
- `ARCHS` (default `arm64`)
- `DEPLOYMENT_TARGET` (default `26.0`)
- `ALEMBIC_TAG` (override tag auto-detection)
- `EXTRA_CMAKE_FLAGS`
- `DYLIBBUNDLER_SEARCH_PATHS` (default `/opt/homebrew/lib /opt/homebrew/opt/imath/lib`)

## Conventions and gotchas

- **Alembic upstream tags use bare `<version>` (e.g. `1.8.11`)** — no `v` prefix in modern history. The auto-detect tries the bare form first then falls back to `v<version>`.
- **`Headers/Alembic/` nested layout is deliberate** — Alembic's public headers expect `#include <Alembic/Abc/...>`. Don't flatten.
- **Imath is the only required runtime dep** in the default config. If `USE_HDF5=ON`, ensure `brew install hdf5` and confirm it lands in the bundle.
- **Module map ships submodules per Alembic subsystem** (`Util`, `AbcCoreAbstract`, `AbcCoreFactory`, `AbcCoreOgawa`, `AbcCoreHDF5`, `Ogawa`, `Abc`, `AbcCollection`, `AbcGeom`, `AbcMaterial`) using each subsystem's `All.h`. There is no project-wide umbrella header in upstream Alembic.
- **`CMAKE_OSX_DEPLOYMENT_TARGET=26.0`** is high. Keep aligned with the GDAL/PDAL builders.
- **`set -euo pipefail`** is on.

## Relationship to sibling builders

- Same shape (`config.sh`, numbered `build.sh` phases, Makefile targets, work/output dirs) as gdal/pdal builders — keep stylistically aligned when changing one.
- Unlike the PDAL builder, this one does **not** consume any other xcframework — Alembic is a leaf dependency.
- Both default to **no codesign** (Xcode re-signs on Embed & Sign).

## Out of scope

- iOS / Catalyst / x86_64 — untested.
- Patching Alembic source — pure orchestrator over upstream tags.
- PyAlembic, Maya/Arnold/PRMan plugins — disabled (`USE_PYALEMBIC=OFF` etc.).
