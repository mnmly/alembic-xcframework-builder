# CLAUDE.md — alembic-xcframework-builder

## Purpose

Standalone tool that builds an `Alembic.xcframework` for Apple platforms (macOS, iOS, visionOS, tvOS — device + simulator, arm64) from any tagged upstream Alembic release. Lives **outside** the Alembic source tree. Sibling project to `gdal-xcframework-builder` and `pdal-xcframework-builder`.

## Why a builder is needed

Alembic's CMake produces a regular dylib (or `.a`) plus headers under `include/Alembic/...`. It does not emit any kind of Apple `.framework`. This builder does a per-slice CMake install, then assembles the framework structure in shell — same approach as the PDAL builder.

## Linking model

- **macOS slice — dynamic.** `ALEMBIC_SHARED_LIBS=ON`, Imath pulled from Homebrew, bundled into the framework via `dylibbundler`. Uses the versioned `Versions/A/...` framework layout. Preserves the original macOS behaviour.
- **iOS / visionOS / tvOS slices — static.** `ALEMBIC_SHARED_LIBS=OFF`. Imath is vendored from source (pinned by `IMATH_VERSION`) and built statically per slice. The Alembic and Imath `.a` files are merged with `libtool -static` into a single framework binary. Flat (non-versioned) framework layout, no `dylibbundler`, no rpath fixups, no codesign step (Xcode re-signs on Embed & Sign).

The same set of headers + the same `module.modulemap` ship in every slice; only the binary linkage differs.

## Pipeline (build.sh, 5 phases)

1. **Fetch sources** — clone Alembic at tag (auto-detects `<version>` or `v<version>` via `git ls-remote`; override with `ALEMBIC_TAG`). Clone Imath at `v${IMATH_VERSION}` (skipped if `PLATFORMS=macos` only).
2. **Build per-slice Imath (static, non-macOS)** — one CMake configure/build/install per non-macOS slice into `work/.../<slice>/imath-install` with `BUILD_SHARED_LIBS=OFF`. `CMAKE_SYSTEM_NAME` + `CMAKE_OSX_SYSROOT` (from `xcrun --sdk <sdk> --show-sdk-path`) drive cross-compilation.
3. **Build per-slice Alembic** — same cross-compile pattern. macOS slice uses Homebrew Imath via `IMATH_PREFIX`; other slices point `Imath_DIR` at their per-slice Imath install. `USE_HDF5=OFF` always.
4. **Assemble frameworks** — `assemble_macos_framework` (versioned + dylibbundler) for macOS, `assemble_static_framework <slice>` (flat + libtool merge) for all others. Shared `stage_headers` function handles Alembic nested layout, subsystem symlinks at the framework header root, and Imath headers.
5. **Wrap in xcframework + zip** — single `xcodebuild -create-xcframework` with one `-framework` arg per slice; `ditto` zip; `swift package compute-checksum`. Optional `gh release create` if `RELEASE=1` and `GH_RELEASE_REPO` set.

## Files

- `build.sh` — orchestrator
- `resources/module.modulemap` — bundled into every slice's `Modules/`. Edit to change Swift import surface.
- `Makefile` — `xcframework`, `release`, `clean`, `distclean`
- `config.sh.example` — template (user copies to `config.sh`, gitignored)
- `work/`, `output/` — gitignored

## Config knobs (config.sh)

- `PLATFORMS` — slices to build. Default `macos ios ios-sim visionos visionos-sim tvos tvos-sim`. Drop any to skip.
- `IMATH_VERSION` — Imath release vendored for non-macOS slices. Default `3.1.12`.
- `IMATH_PREFIX` — macOS slice only (Homebrew Imath).
- `MACOSX_DEPLOYMENT_TARGET` — default `26.0`.
- `IOS_DEPLOYMENT_TARGET` — default `17.0`.
- `VISIONOS_DEPLOYMENT_TARGET` — default `2.0`.
- `TVOS_DEPLOYMENT_TARGET` — default `17.0`.
- `CODESIGN_IDENTITY` — optional; macOS slice only.
- `OUTPUT_DIR` — default `./output`.
- `SWIFT_PACKAGE_FRAMEWORKS_DIR` — optional mirror dest.
- `GH_RELEASE_REPO` — for `make release`.
- `ALEMBIC_TAG` — override tag auto-detection.
- `EXTRA_CMAKE_FLAGS` — appended to every Alembic configure step.
- `DYLIBBUNDLER_SEARCH_PATHS` — macOS slice only.

## Conventions and gotchas

- **Alembic upstream tags use bare `<version>` (e.g. `1.8.11`)** — no `v` prefix in modern history. Imath uses `v<version>` (e.g. `v3.1.12`).
- **`Headers/Alembic/` nested layout is deliberate** — Alembic's public headers expect `#include <Alembic/Abc/...>`. Don't flatten. The root-level subsystem entries (`Headers/Abc`, `Headers/Util`, etc.) are symlinks for framework lookup compatibility, not the canonical install layout.
- **Imath headers are part of the compile surface** — every slice ships `Headers/Imath` because Alembic's public headers `#include <Imath/...>`.
- **macOS slice has a `Libraries/` dir with bundled Imath dylib; other slices do not** — Imath is statically linked into the framework binary on iOS/visionOS/tvOS.
- **Static framework binary is a Mach-O `ar` archive** named `Alembic` (no extension) — `xcodebuild -create-xcframework` accepts this.
- **Module map ships submodules per Alembic subsystem** (`Util`, `AbcCoreAbstract`, `AbcCoreFactory`, `AbcCoreOgawa`, `Ogawa`, `Abc`, `AbcCollection`, `AbcGeom`, `AbcMaterial`) using each subsystem's `All.h`. `AbcCoreHDF5` was removed when HDF5 was dropped.
- **HDF5 is intentionally unsupported** — Ogawa is the modern back-end; HDF5 is read-only legacy with cross-compile costs we don't want.
- **Simulator slices share `CMAKE_SYSTEM_NAME` with their device counterparts**; the SDK sysroot from `xcrun --sdk iphonesimulator` (etc.) is what distinguishes them.
- **`set -euo pipefail`** is on.

## Relationship to sibling builders

- Same shape (`config.sh`, numbered `build.sh` phases, Makefile targets, work/output dirs) as gdal/pdal builders — keep stylistically aligned when changing one.
- Unlike the PDAL builder, this one does **not** consume any other xcframework — Alembic is a leaf dependency.
- Default: **no codesign** (Xcode re-signs on Embed & Sign).

## Out of scope

- Mac Catalyst / x86_64 — not built.
- Patching Alembic source — pure orchestrator over upstream tags.
- HDF5 back-end.
- PyAlembic, Maya/Arnold/PRMan plugins — disabled.
