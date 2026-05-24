# alembic-xcframework-builder

Builds `Alembic.xcframework` for macOS (arm64) from a tagged upstream Alembic release.

Sibling project to `gdal-xcframework-builder` and `pdal-xcframework-builder`. Same shape: `config.sh`, numbered `build.sh` phases, `Makefile`, `work/` and `output/` dirs.

## Prereqs

```sh
brew install cmake dylibbundler imath
# optional, only if you set USE_HDF5=ON in config.sh:
brew install hdf5
```

## Setup

```sh
cp config.sh.example config.sh
# edit if you need to override IMATH_PREFIX, deployment target, codesign, etc.
```

## Build

```sh
make ALEMBIC_VERSION=1.8.11 xcframework
# → output/Alembic.xcframework  +  output/Alembic.xcframework.zip
```

Optional release upload:

```sh
# set GH_RELEASE_REPO=owner/repo in config.sh first
make ALEMBIC_VERSION=1.8.11 release
```

## What it does

Alembic's CMake produces a regular `libAlembic.<version>.dylib` plus headers — no `.framework`. `build.sh` does a normal install, then assembles a proper macOS framework structure (`Versions/A/{Alembic, Headers, Modules, Libraries, Resources}`), bundles Imath via `dylibbundler`, normalises rpaths, and wraps it in an xcframework.

Headers are staged in the canonical upstream layout at `Headers/Alembic/...`. The framework also adds root-level subsystem symlinks such as `Headers/Abc -> Alembic/Abc` so Clang framework lookup can resolve Alembic's own `#include <Alembic/Abc/...>` form without consumers adding a manual `-I Alembic.framework/Headers`. Imath public headers are copied to `Headers/Imath` for consumers that do add the framework headers as an include root.

The Swift module map is at `resources/module.modulemap` — edit it to change the import surface.

## Config knobs (config.sh)

- `IMATH_PREFIX` — Homebrew prefix for Imath (auto-detected via `brew --prefix imath`)
- `USE_HDF5` — `OFF` (default) or `ON`. Adds the legacy HDF5 backend.
- `CODESIGN_IDENTITY` — optional; usually leave empty (Xcode re-signs on Embed & Sign)
- `OUTPUT_DIR` — default `./output`
- `SWIFT_PACKAGE_FRAMEWORKS_DIR` — optional mirror destination
- `GH_RELEASE_REPO` — for `make release`
- `ARCHS` — default `arm64`
- `DEPLOYMENT_TARGET` — default `26.0` (keep aligned with the GDAL/PDAL builders)
- `ALEMBIC_TAG` — override tag auto-detection
- `EXTRA_CMAKE_FLAGS`
- `DYLIBBUNDLER_SEARCH_PATHS`

## Make targets

- `make ALEMBIC_VERSION=X xcframework`
- `make ALEMBIC_VERSION=X release`
- `make clean` — removes `work/`
- `make distclean` — removes `work/` and `output/`
