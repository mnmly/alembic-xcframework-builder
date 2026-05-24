# alembic-xcframework-builder

Builds `Alembic.xcframework` for Apple platforms (macOS, iOS, visionOS, tvOS — device + simulator, arm64) from a tagged upstream Alembic release.

Sibling project to `gdal-xcframework-builder` and `pdal-xcframework-builder`. Same shape: `config.sh`, numbered `build.sh` phases, `Makefile`, `work/` and `output/` dirs.

## Prereqs

```sh
brew install cmake dylibbundler imath
```

`dylibbundler` and Homebrew `imath` are only used by the macOS slice. iOS/visionOS/tvOS slices build their own static Imath from source.

## Setup

```sh
cp config.sh.example config.sh
# edit PLATFORMS if you want to skip slices, override deployment targets, etc.
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

Alembic's CMake produces a regular dylib or static archive plus headers — no `.framework`. `build.sh` installs Alembic per slice, then assembles a framework around each one and wraps the lot into a single xcframework.

- **macOS slice (dynamic):** versioned `Versions/A/{Alembic, Headers, Modules, Libraries, Resources}` layout, Imath pulled in via `dylibbundler`, rpaths normalised.
- **iOS / visionOS / tvOS slices (static):** flat framework layout. Imath is built statically from source per-slice and merged into a single static archive (`libtool -static`) that becomes the framework binary. No `dylibbundler`, no rpath fixups.

Headers are staged in the canonical upstream layout at `Headers/Alembic/...`. Each slice also adds root-level subsystem symlinks (`Headers/Abc -> Alembic/Abc`, etc.) so Clang framework lookup can resolve Alembic's own `#include <Alembic/Abc/...>` form.

## Consumer setup

Alembic's public headers do `#include <Imath/half.h>`. Clang's `-F` framework search resolves `<X/Y>` as `X.framework/Headers/Y`, which works for `<Alembic/...>` but NOT for `<Imath/...>` because we don't ship a separate Imath framework. Add `Alembic.framework/Headers` to your `HEADER_SEARCH_PATHS` (or pass `-I .../Alembic.framework/Headers`) so the bundled `Headers/Imath/` directory is visible to the include resolver. Example for Xcode build settings:

```
HEADER_SEARCH_PATHS = $(inherited) "$(BUILT_PRODUCTS_DIR)/Alembic.framework/Headers"
```

HDF5 is not supported. Ogawa is Alembic's modern back-end; HDF5 is read-only legacy and cross-compiling it isn't worth the cost.

The Swift module map is at `resources/module.modulemap` — edit it to change the import surface.

## Config knobs (config.sh)

- `PLATFORMS` — slices to build. Default: `macos ios ios-sim visionos visionos-sim tvos tvos-sim`. Drop any you don't need.
- `IMATH_VERSION` — Imath release vendored for non-macOS slices. Default `3.1.12`.
- `IMATH_PREFIX` — Homebrew prefix for Imath, used only by the macOS slice.
- `MACOSX_DEPLOYMENT_TARGET` — default `26.0` (keep aligned with the GDAL/PDAL builders).
- `IOS_DEPLOYMENT_TARGET` — default `17.0`.
- `VISIONOS_DEPLOYMENT_TARGET` — default `2.0`.
- `TVOS_DEPLOYMENT_TARGET` — default `17.0`.
- `CODESIGN_IDENTITY` — optional; applies to macOS slice only (Xcode re-signs on Embed & Sign).
- `OUTPUT_DIR` — default `./output`.
- `SWIFT_PACKAGE_FRAMEWORKS_DIR` — optional mirror destination.
- `GH_RELEASE_REPO` — for `make release`.
- `ALEMBIC_TAG` — override tag auto-detection.
- `EXTRA_CMAKE_FLAGS` — appended to every Alembic configure step.
- `DYLIBBUNDLER_SEARCH_PATHS` — macOS slice only.

## Make targets

- `make ALEMBIC_VERSION=X xcframework`
- `make ALEMBIC_VERSION=X release`
- `make clean` — removes `work/`
- `make distclean` — removes `work/` and `output/`
