#!/bin/bash
# Build Alembic.xcframework for macOS from a tagged upstream Alembic release.
#
# Alembic's CMake produces a regular shared dylib + headers — no .framework.
# This script does a normal install, then assembles a proper macOS framework
# structure from the install output (same approach as the PDAL builder).
#
# Usage: ./build.sh <ALEMBIC_VERSION>           e.g. ./build.sh 1.8.11
#        RELEASE=1 ./build.sh <ALEMBIC_VERSION>
set -euo pipefail

ALEMBIC_VERSION="${1:-}"
if [ -z "${ALEMBIC_VERSION}" ]; then
    echo "Usage: $0 <ALEMBIC_VERSION>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "${ROOT}/config.sh" ]; then
    echo "Missing ${ROOT}/config.sh — copy config.sh.example and edit it." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "${ROOT}/config.sh"

: "${IMATH_PREFIX:?IMATH_PREFIX must be set in config.sh}"
: "${OUTPUT_DIR:=${ROOT}/output}"
: "${ARCHS:=arm64}"
: "${DEPLOYMENT_TARGET:=26.0}"
: "${USE_HDF5:=OFF}"
: "${EXTRA_CMAKE_FLAGS:=}"
: "${DYLIBBUNDLER_SEARCH_PATHS:=/opt/homebrew/lib /opt/homebrew/opt/imath/lib}"

# Preflight
missing=()
for cmd in cmake dylibbundler xcodebuild git plutil otool install_name_tool; do
    command -v "$cmd" >/dev/null || missing+=("$cmd (command)")
done
[ -d "${IMATH_PREFIX}/lib/cmake/Imath" ] || missing+=("imath cmake config at ${IMATH_PREFIX}/lib/cmake/Imath (brew install imath)")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "Install with:  brew install cmake dylibbundler imath" >&2
    exit 1
fi

IMATH_DIR="${IMATH_PREFIX}/lib/cmake/Imath"

WORK="${ROOT}/work/alembic-${ALEMBIC_VERSION}"
SRC_DIR="${WORK}/src"
BUILD_DIR="${WORK}/build"
INSTALL_DIR="${WORK}/install"
STAGE="${WORK}/stage"               # where we assemble the .framework
FW="${STAGE}/Alembic.framework"

mkdir -p "${OUTPUT_DIR}"

cmake_arch_flag=""
for a in ${ARCHS}; do cmake_arch_flag="${cmake_arch_flag};${a}"; done
cmake_arch_flag="${cmake_arch_flag#;}"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

############################################
step "1/8  Fetch Alembic ${ALEMBIC_VERSION}"
############################################
if [ -z "${ALEMBIC_TAG:-}" ]; then
    if git ls-remote --tags https://github.com/alembic/alembic.git "refs/tags/${ALEMBIC_VERSION}" \
        | grep -q "${ALEMBIC_VERSION}"; then
        ALEMBIC_TAG="${ALEMBIC_VERSION}"
    else
        ALEMBIC_TAG="v${ALEMBIC_VERSION}"
    fi
fi
echo "using tag: ${ALEMBIC_TAG}"

if [ ! -d "${SRC_DIR}/.git" ]; then
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "${ALEMBIC_TAG}" \
        https://github.com/alembic/alembic.git "${SRC_DIR}"
else
    echo "source already present at ${SRC_DIR}"
fi

############################################
step "2/8  Configure"
############################################
rm -rf "${BUILD_DIR}" "${INSTALL_DIR}" "${STAGE}"
mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}" "${STAGE}"

cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DALEMBIC_SHARED_LIBS=ON \
    -DALEMBIC_BUILD_LIBS=ON \
    -DUSE_BINARIES=OFF \
    -DUSE_EXAMPLES=OFF \
    -DUSE_TESTS=OFF \
    -DUSE_HDF5="${USE_HDF5}" \
    -DImath_DIR="${IMATH_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES="${cmake_arch_flag}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_FIND_FRAMEWORK=LAST \
    ${EXTRA_CMAKE_FLAGS}

############################################
step "3/8  Build + install"
############################################
cmake --build "${BUILD_DIR}" -j "$(sysctl -n hw.ncpu)"
cmake --install "${BUILD_DIR}"

# Sanity check — find the versioned dylib (libAlembic.X.Y.Z.dylib).
ALEMBIC_DYLIB_REAL="$(find "${INSTALL_DIR}/lib" -maxdepth 1 -name "libAlembic.*.*.*.dylib" -type f | head -1)"
if [ -z "${ALEMBIC_DYLIB_REAL}" ]; then
    # Fallback: some Alembic builds stamp only soversion (libAlembic.1.dylib).
    ALEMBIC_DYLIB_REAL="$(find "${INSTALL_DIR}/lib" -maxdepth 1 -name "libAlembic.*.dylib" -type f ! -name "libAlembic.dylib" | head -1)"
fi
if [ -z "${ALEMBIC_DYLIB_REAL}" ]; then
    echo "Could not locate the installed libAlembic dylib in ${INSTALL_DIR}/lib" >&2
    ls -la "${INSTALL_DIR}/lib" >&2 || true
    exit 1
fi
echo "found dylib: ${ALEMBIC_DYLIB_REAL}"

############################################
step "4/8  Assemble framework structure"
############################################
mkdir -p \
    "${FW}/Versions/A/Headers" \
    "${FW}/Versions/A/Modules" \
    "${FW}/Versions/A/Libraries" \
    "${FW}/Versions/A/Resources"

# Binary
cp "${ALEMBIC_DYLIB_REAL}" "${FW}/Versions/A/Alembic"
chmod +w "${FW}/Versions/A/Alembic"
install_name_tool -id "@rpath/Alembic.framework/Versions/A/Alembic" \
    "${FW}/Versions/A/Alembic"

# Compatibility symlinks so anything linked against libAlembic.<soversion>.dylib
# still resolves to the framework binary.
DYLIB_BASENAME="$(basename "${ALEMBIC_DYLIB_REAL}")"
SOVERSION="$(echo "${DYLIB_BASENAME}" | sed -E 's/^libAlembic\.([0-9]+).*\.dylib$/\1/')"
( cd "${FW}/Versions/A" && \
    ln -sf Alembic "libAlembic.${SOVERSION}.dylib" && \
    ln -sf Alembic "libAlembic.dylib" )

# Headers (Headers/Alembic/...). Alembic installs to include/Alembic/<Module>/*.h
cp -R "${INSTALL_DIR}/include/Alembic" "${FW}/Versions/A/Headers/Alembic"

# Modulemap
cp "${ROOT}/resources/module.modulemap" "${FW}/Versions/A/Modules/module.modulemap"

# Info.plist
PLIST="${FW}/Versions/A/Resources/Info.plist"
cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>English</string>
    <key>CFBundleExecutable</key>             <string>Alembic</string>
    <key>CFBundleIdentifier</key>             <string>io.alembic.Alembic</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>Alembic</string>
    <key>CFBundlePackageType</key>            <string>FMWK</string>
    <key>CFBundleShortVersionString</key>     <string>${ALEMBIC_VERSION}</string>
    <key>CFBundleVersion</key>                <string>${ALEMBIC_VERSION}</string>
    <key>CFBundleSignature</key>              <string>????</string>
    <key>CSResourcesFileMapped</key>          <true/>
</dict>
</plist>
EOF
plutil -lint "${PLIST}" >/dev/null

# Upstream license — Alembic is BSD-3-Clause; binary redistribution must
# carry the notice. Ship it inside the framework's Resources/.
LICENSE_SRC="$(find "${SRC_DIR}" -maxdepth 1 -type f -iname 'license*' | head -1)"
if [ -n "${LICENSE_SRC}" ]; then
    cp "${LICENSE_SRC}" "${FW}/Versions/A/Resources/LICENSE.txt"
else
    echo "warning: no LICENSE file found in ${SRC_DIR}" >&2
fi

############################################
step "5/8  Bundle dylib deps + fix rpaths"
############################################
search_flags=()
for p in ${DYLIBBUNDLER_SEARCH_PATHS}; do
    [ -d "$p" ] && search_flags+=("-s" "$p")
done

cd "${STAGE}"
dylibbundler -od -b -x "./Alembic.framework/Versions/A/Alembic" \
    -d "./Alembic.framework/Versions/A/Libraries/" \
    -p "@loader_path/Libraries/" \
    "${search_flags[@]}"

# Dedupe duplicate `@loader_path/Libraries/` rpaths.
dedupe_rpath() {
    local target="$1" path="$2"
    local count
    count=$(otool -l "$target" | grep -c "path ${path} " || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    while [ "$count" -gt 1 ]; do
        install_name_tool -delete_rpath "$path" "$target" 2>/dev/null || break
        count=$(otool -l "$target" | grep -c "path ${path} " || true)
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
    done
}

dedupe_rpath "./Alembic.framework/Versions/A/Alembic" "@loader_path/Libraries/"

# Normalise rpaths inside bundled dylibs.
for lib in ./Alembic.framework/Versions/A/Libraries/*.dylib; do
    [ -e "$lib" ] || continue
    dedupe_rpath "$lib" "@loader_path/Libraries/"
    count=$(otool -l "$lib" | grep -c "cmd LC_RPATH" || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if [ "$count" -eq 0 ]; then
        install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
    fi
    otool -L "$lib" | awk '/@loader_path\/Libraries\//{print $1}' | while read -r dep; do
        libname="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/$libname" "$lib" 2>/dev/null || true
    done
done

############################################
step "6/8  Top-level framework symlinks"
############################################
( cd "${FW}/Versions" && ln -sfn A Current )
( cd "${FW}" && \
    ln -sfn Versions/Current/Alembic Alembic && \
    ln -sfn Versions/Current/Headers Headers && \
    ln -sfn Versions/Current/Modules Modules && \
    ln -sfn Versions/Current/Libraries Libraries && \
    ln -sfn Versions/Current/Resources Resources )

############################################
step "7/8  Codesign (optional)"
############################################
SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "signing inside-out with identity: ${SIGN_ID}"
find "${FW}/Versions/A" -type f \( -name "*.dylib" -o -name "Alembic" \) \
    -exec codesign --force --sign "${SIGN_ID}" --timestamp=none {} \;
codesign --force --sign "${SIGN_ID}" --timestamp=none --deep "${FW}"

############################################
step "8/8  Wrap in xcframework + zip"
############################################
XC_OUT="${OUTPUT_DIR}/Alembic.xcframework"
rm -rf "${XC_OUT}"
xcodebuild -create-xcframework -framework "${FW}" -output "${XC_OUT}"

if [ -n "${SWIFT_PACKAGE_FRAMEWORKS_DIR:-}" ]; then
    mkdir -p "${SWIFT_PACKAGE_FRAMEWORKS_DIR}"
    rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/Alembic.xcframework"
    cp -R "${XC_OUT}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
    echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/Alembic.xcframework"
fi

cd "${OUTPUT_DIR}"
ZIP="Alembic.xcframework.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent Alembic.xcframework "${ZIP}"

CHECKSUM=""
if command -v swift >/dev/null 2>&1; then
    CHECKSUM="$(swift package compute-checksum "${ZIP}")"
fi

printf "\n\033[1;32mDONE\033[0m  %s\n" "${XC_OUT}"
printf "      zip: %s\n" "${OUTPUT_DIR}/${ZIP}"
[ -n "${CHECKSUM}" ] && printf "      swift checksum: %s\n" "${CHECKSUM}"

if [ "${RELEASE:-0}" = "1" ]; then
    if [ -z "${GH_RELEASE_REPO:-}" ]; then
        echo "RELEASE=1 set but GH_RELEASE_REPO is empty in config.sh — skipping gh release" >&2
        exit 0
    fi
    TAG="alembic-v${ALEMBIC_VERSION}"
    step "Publishing gh release ${TAG} to ${GH_RELEASE_REPO}"
    gh release create "${TAG}" "${OUTPUT_DIR}/${ZIP}" \
        --repo "${GH_RELEASE_REPO}" \
        --title "Alembic v${ALEMBIC_VERSION} Framework" \
        --notes "Binary framework for Alembic v${ALEMBIC_VERSION}"
fi
