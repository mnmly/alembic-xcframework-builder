# CLAUDE.md — alembic-xcframework-builder

## Purpose

Standalone tool that builds an `Alembic.xcframework` for Apple platforms (macOS, iOS, visionOS, tvOS — device + simulator, arm64) from any tagged upstream Alembic release. Lives **outside** the Alembic source tree. Sibling project to `gdal-xcframework-builder` and `pdal-xcframework-builder`.

## Why a builder is needed

Alembic's CMake produces a regular dylib (or `.a`) plus headers under `include/Alembic/...`. It does not emit any kind of Apple `.framework`. This builder does a per-slice CMake install, then assembles the framework structure in shell — same approach as the PDAL builder.

## Linking model

Every slice links against the same vendored Imath (pinned by `IMATH_VERSION`, built static + PIC per slice). This is load-bearing: Alembic's public API exposes `Imath::Vec3<double>` and similar types in C++ symbol mangling, and Imath's `IMATH_INTERNAL_NAMESPACE` (`Imath_3_1`, `Imath_3_2`, …) becomes part of every mangled name. If two slices have different Imath versions, a consumer C++ shim built against one slice's headers won't link against another slice's binary.

- **macOS slice — dynamic.** `ALEMBIC_SHARED_LIBS=ON`, Imath statically linked into `libAlembic.dylib` (no separate Imath dylib, no `dylibbundler`). Uses the versioned `Versions/A/...` framework layout. A build-time check asserts `libAlembic.dylib` has no external `libImath` dependency.
- **iOS / visionOS / tvOS slices — static.** `ALEMBIC_SHARED_LIBS=OFF`. The Alembic and Imath `.a` files are merged with `libtool -static` into a single framework binary. Flat (non-versioned) framework layout, no codesign step (Xcode re-signs on Embed & Sign).

The same headers + module map ship in every slice; only the binary linkage differs. A post-build invariant grep-compares `IMATH_VERSION_STRING` and `IMATH_INTERNAL_NAMESPACE` from every slice's `Headers/Imath/ImathConfig.h` and fails the build if they diverge.

## Pipeline (build.sh, 5 phases)

1. **Fetch sources** — clone Alembic at tag (auto-detects `<version>` or `v<version>` via `git ls-remote`; override with `ALEMBIC_TAG`). Clone Imath at `v${IMATH_VERSION}`.
2. **Build per-slice Imath (static + PIC)** — one CMake configure/build/install per slice (including macOS) into `work/.../<slice>/imath-install` with `BUILD_SHARED_LIBS=OFF` and `CMAKE_POSITION_INDEPENDENT_CODE=ON`. PIC is required so the macOS slice can link static Imath into a dynamic Alembic dylib. `CMAKE_SYSTEM_NAME` + `CMAKE_OSX_SYSROOT` (from `xcrun --sdk <sdk> --show-sdk-path`) drive cross-compilation.
3. **Build per-slice Alembic** — same cross-compile pattern. Every slice points `Imath_DIR` at its per-slice Imath install (no Homebrew). `USE_HDF5=OFF` always.
4. **Assemble frameworks** — `assemble_macos_framework` (versioned, dynamic, no dylibbundler) for macOS, `assemble_static_framework <slice>` (flat + libtool merge) for all others. Shared `stage_headers` function handles Alembic nested layout, subsystem symlinks at the framework header root, and Imath headers — Imath headers come from the vendored install on every slice.
5. **Verify Imath ABI consistency + wrap in xcframework + zip** — invariant check that every slice's `Headers/Imath/ImathConfig.h` declares the same `IMATH_VERSION_STRING` and `IMATH_INTERNAL_NAMESPACE`; then `xcodebuild -create-xcframework`; `ditto` zip; `swift package compute-checksum`. Optional `gh release create` if `RELEASE=1` and `GH_RELEASE_REPO` set.

## Files

- `build.sh` — orchestrator
- `resources/module.modulemap` — bundled into every slice's `Modules/`. Edit to change Swift import surface.
- `Makefile` — `xcframework`, `release`, `clean`, `distclean`
- `config.sh.example` — template (user copies to `config.sh`, gitignored)
- `work/`, `output/` — gitignored

## Config knobs (config.sh)

- `PLATFORMS` — slices to build. Default `macos ios ios-sim visionos visionos-sim tvos tvos-sim`. Drop any to skip.
- `IMATH_VERSION` — Imath release vendored for every slice. Default `3.1.12`.
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

`IMATH_PREFIX` and `DYLIBBUNDLER_SEARCH_PATHS` were removed: Imath is vendored from source for every slice (including macOS) and `dylibbundler` is no longer used.

## Conventions and gotchas

- **Alembic upstream tags use bare `<version>` (e.g. `1.8.11`)** — no `v` prefix in modern history. Imath uses `v<version>` (e.g. `v3.1.12`).
- **`Headers/Alembic/` nested layout is deliberate** — Alembic's public headers expect `#include <Alembic/Abc/...>`. Don't flatten. The root-level subsystem entries (`Headers/Abc`, `Headers/Util`, etc.) are symlinks for framework lookup compatibility, not the canonical install layout.
- **Imath headers are part of the compile surface** — every slice ships `Headers/Imath` because Alembic's public headers `#include <Imath/...>`. The headers must match the Imath that was linked into that slice's binary — see the Imath ABI invariant above.
- **No `Libraries/` dir on any slice** — Imath is statically linked into the framework binary on every platform.
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
