#!/bin/bash
# Build Alembic.xcframework for Apple platforms from a tagged upstream Alembic
# release. macOS slice is shipped dynamic (with Imath bundled via dylibbundler);
# iOS / visionOS / tvOS device + simulator slices are static (Imath linked in).
# HDF5 is intentionally not supported — Ogawa is the modern back-end and HDF5
# adds cross-compile cost we don't need.
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
    echo "Missing ${ROOT}/config.sh — copy config.sh.example and edit." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "${ROOT}/config.sh"

: "${PLATFORMS:=macos ios ios-sim visionos visionos-sim tvos tvos-sim}"
: "${IMATH_VERSION:=3.1.12}"
: "${IMATH_PREFIX:?IMATH_PREFIX must be set in config.sh (used by macos slice)}"
: "${OUTPUT_DIR:=${ROOT}/output}"
: "${MACOSX_DEPLOYMENT_TARGET:=26.0}"
: "${IOS_DEPLOYMENT_TARGET:=17.0}"
: "${VISIONOS_DEPLOYMENT_TARGET:=2.0}"
: "${TVOS_DEPLOYMENT_TARGET:=17.0}"
: "${EXTRA_CMAKE_FLAGS:=}"
: "${DYLIBBUNDLER_SEARCH_PATHS:=/opt/homebrew/lib /opt/homebrew/opt/imath/lib}"

needs_macos=0
for slice in ${PLATFORMS}; do
    [ "${slice}" = "macos" ] && needs_macos=1
done

# Preflight
missing=()
core_cmds=(cmake xcodebuild git plutil otool install_name_tool libtool xcrun)
[ "${needs_macos}" = "1" ] && core_cmds+=(dylibbundler)
for cmd in "${core_cmds[@]}"; do
    command -v "$cmd" >/dev/null || missing+=("$cmd (command)")
done
if [ "${needs_macos}" = "1" ]; then
    [ -d "${IMATH_PREFIX}/lib/cmake/Imath" ] || \
        missing+=("imath cmake config at ${IMATH_PREFIX}/lib/cmake/Imath (brew install imath)")
fi
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    [ "${needs_macos}" = "1" ] && echo "Install with:  brew install cmake dylibbundler imath" >&2
    exit 1
fi

WORK="${ROOT}/work/alembic-${ALEMBIC_VERSION}"
SRC_DIR="${WORK}/src"
STAGE_ROOT="${WORK}/stage"
IMATH_SRC="${ROOT}/work/imath-${IMATH_VERSION}/src"

mkdir -p "${OUTPUT_DIR}" "${STAGE_ROOT}"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

# ----------------------------------------------------------------------------
# Slice metadata
# ----------------------------------------------------------------------------
# slice_system_name <slice>  -> CMAKE_SYSTEM_NAME
slice_system_name() {
    case "$1" in
        macos)                    echo "Darwin" ;;
        ios|ios-sim)              echo "iOS" ;;
        visionos|visionos-sim)    echo "visionOS" ;;
        tvos|tvos-sim)            echo "tvOS" ;;
        *) echo "unknown slice: $1" >&2; exit 1 ;;
    esac
}

slice_sdk() {
    case "$1" in
        macos)         echo "macosx" ;;
        ios)           echo "iphoneos" ;;
        ios-sim)       echo "iphonesimulator" ;;
        visionos)      echo "xros" ;;
        visionos-sim)  echo "xrsimulator" ;;
        tvos)          echo "appletvos" ;;
        tvos-sim)      echo "appletvsimulator" ;;
    esac
}

slice_deployment_target() {
    case "$1" in
        macos)                    echo "${MACOSX_DEPLOYMENT_TARGET}" ;;
        ios|ios-sim)              echo "${IOS_DEPLOYMENT_TARGET}" ;;
        visionos|visionos-sim)    echo "${VISIONOS_DEPLOYMENT_TARGET}" ;;
        tvos|tvos-sim)            echo "${TVOS_DEPLOYMENT_TARGET}" ;;
    esac
}

# Value for CFBundleSupportedPlatforms in Info.plist
slice_platform_name() {
    case "$1" in
        macos)         echo "MacOSX" ;;
        ios)           echo "iPhoneOS" ;;
        ios-sim)       echo "iPhoneSimulator" ;;
        visionos)      echo "XROS" ;;
        visionos-sim) echo "XRSimulator" ;;
        tvos)          echo "AppleTVOS" ;;
        tvos-sim)      echo "AppleTVSimulator" ;;
    esac
}

# ----------------------------------------------------------------------------
# Fetch sources (idempotent)
# ----------------------------------------------------------------------------
fetch_alembic() {
    if [ -z "${ALEMBIC_TAG:-}" ]; then
        if git ls-remote --tags https://github.com/alembic/alembic.git \
            "refs/tags/${ALEMBIC_VERSION}" | grep -q "${ALEMBIC_VERSION}"; then
            ALEMBIC_TAG="${ALEMBIC_VERSION}"
        else
            ALEMBIC_TAG="v${ALEMBIC_VERSION}"
        fi
    fi
    echo "Alembic tag: ${ALEMBIC_TAG}"
    if [ ! -d "${SRC_DIR}/.git" ]; then
        rm -rf "${SRC_DIR}"
        git clone --depth 1 --branch "${ALEMBIC_TAG}" \
            https://github.com/alembic/alembic.git "${SRC_DIR}"
    else
        echo "Alembic source already at ${SRC_DIR}"
    fi
}

fetch_imath() {
    [ "${PLATFORMS}" = "macos" ] && return 0
    if [ ! -d "${IMATH_SRC}/.git" ]; then
        rm -rf "${IMATH_SRC}"
        git clone --depth 1 --branch "v${IMATH_VERSION}" \
            https://github.com/AcademySoftwareFoundation/Imath.git "${IMATH_SRC}"
    else
        echo "Imath source already at ${IMATH_SRC}"
    fi
}

# ----------------------------------------------------------------------------
# Per-slice Imath build (static, non-macOS only)
# ----------------------------------------------------------------------------
build_imath_static() {
    local slice="$1"
    local sys; sys="$(slice_system_name "${slice}")"
    local sdk; sdk="$(slice_sdk "${slice}")"
    local dep; dep="$(slice_deployment_target "${slice}")"
    local sysroot; sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    local prefix="${WORK}/${slice}/imath-install"
    local build_dir="${WORK}/${slice}/imath-build"

    rm -rf "${build_dir}" "${prefix}"
    mkdir -p "${build_dir}" "${prefix}"

    cmake -S "${IMATH_SRC}" -B "${build_dir}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}" \
        -DCMAKE_SYSTEM_NAME="${sys}" \
        -DCMAKE_OSX_SYSROOT="${sysroot}" \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${dep}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DIMATH_INSTALL_PKG_CONFIG=OFF \
        -DPYTHON=OFF \
        -DCMAKE_POLICY_DEFAULT_CMP0077=NEW
    cmake --build "${build_dir}" -j "$(sysctl -n hw.ncpu)" --config Release
    cmake --install "${build_dir}" --config Release
}

# ----------------------------------------------------------------------------
# Per-slice Alembic build
# ----------------------------------------------------------------------------
build_alembic() {
    local slice="$1"
    local sys; sys="$(slice_system_name "${slice}")"
    local sdk; sdk="$(slice_sdk "${slice}")"
    local dep; dep="$(slice_deployment_target "${slice}")"
    local build_dir="${WORK}/${slice}/build"
    local install_dir="${WORK}/${slice}/install"

    rm -rf "${build_dir}" "${install_dir}"
    mkdir -p "${build_dir}" "${install_dir}"

    local shared_flag imath_dir
    if [ "${slice}" = "macos" ]; then
        shared_flag="ON"
        imath_dir="${IMATH_PREFIX}/lib/cmake/Imath"
    else
        shared_flag="OFF"
        imath_dir="${WORK}/${slice}/imath-install/lib/cmake/Imath"
    fi

    local extra_args=()
    if [ "${slice}" != "macos" ]; then
        local sysroot; sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
        extra_args+=(
            -DCMAKE_SYSTEM_NAME="${sys}"
            -DCMAKE_OSX_SYSROOT="${sysroot}"
        )
    fi

    cmake -S "${SRC_DIR}" -B "${build_dir}" \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" \
        -DALEMBIC_SHARED_LIBS="${shared_flag}" \
        -DALEMBIC_BUILD_LIBS=ON \
        -DUSE_BINARIES=OFF \
        -DUSE_EXAMPLES=OFF \
        -DUSE_TESTS=OFF \
        -DUSE_HDF5=OFF \
        -DImath_DIR="${imath_dir}" \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${dep}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_FIND_FRAMEWORK=LAST \
        ${extra_args[@]+"${extra_args[@]}"} \
        ${EXTRA_CMAKE_FLAGS}

    cmake --build "${build_dir}" -j "$(sysctl -n hw.ncpu)" --config Release
    cmake --install "${build_dir}" --config Release
}

# ----------------------------------------------------------------------------
# Header staging shared by all slices
# ----------------------------------------------------------------------------
# stage_headers <headers_dir> <alembic_install_include> <imath_include>
stage_headers() {
    local headers_dir="$1" alembic_inc="$2" imath_inc="$3"
    cp -R "${alembic_inc}/Alembic" "${headers_dir}/Alembic"

    # Subsystem symlinks at Headers/ root so Clang resolves
    # `#include <Alembic/Abc/...>` against Headers/<Subsystem>/...
    while IFS= read -r subsystem; do
        local name; name="$(basename "${subsystem}")"
        ( cd "${headers_dir}" && ln -sfn "Alembic/${name}" "${name}" )
    done < <(find "${headers_dir}/Alembic" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ ! -d "${imath_inc}/Imath" ]; then
        echo "Could not locate Imath headers at ${imath_inc}/Imath" >&2
        exit 1
    fi
    cp -R "${imath_inc}/Imath" "${headers_dir}/Imath"

    test -f "${headers_dir}/Abc/All.h"
    test -f "${headers_dir}/Imath/half.h"
}

# ----------------------------------------------------------------------------
# Info.plist writers
# ----------------------------------------------------------------------------
write_macos_info_plist() {
    local plist="$1"
    cat > "${plist}" <<EOF
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
    plutil -lint "${plist}" >/dev/null
}

write_static_info_plist() {
    local plist="$1" slice="$2"
    local platform_name; platform_name="$(slice_platform_name "${slice}")"
    local min_os; min_os="$(slice_deployment_target "${slice}")"
    cat > "${plist}" <<EOF
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
    <key>CFBundleSupportedPlatforms</key>     <array><string>${platform_name}</string></array>
    <key>MinimumOSVersion</key>               <string>${min_os}</string>
</dict>
</plist>
EOF
    plutil -lint "${plist}" >/dev/null
}

# ----------------------------------------------------------------------------
# Framework assembly
# ----------------------------------------------------------------------------
assemble_macos_framework() {
    local slice="macos"
    local install_dir="${WORK}/${slice}/install"
    local fw="${STAGE_ROOT}/${slice}/Alembic.framework"
    rm -rf "${fw}"
    mkdir -p \
        "${fw}/Versions/A/Headers" \
        "${fw}/Versions/A/Modules" \
        "${fw}/Versions/A/Libraries" \
        "${fw}/Versions/A/Resources"

    local dylib_real
    dylib_real="$(find "${install_dir}/lib" -maxdepth 1 -name "libAlembic.*.*.*.dylib" -type f | head -1)"
    if [ -z "${dylib_real}" ]; then
        dylib_real="$(find "${install_dir}/lib" -maxdepth 1 -name "libAlembic.*.dylib" -type f ! -name "libAlembic.dylib" | head -1)"
    fi
    if [ -z "${dylib_real}" ]; then
        echo "Could not locate installed libAlembic dylib in ${install_dir}/lib" >&2
        ls -la "${install_dir}/lib" >&2 || true
        exit 1
    fi
    echo "macOS dylib: ${dylib_real}"

    cp "${dylib_real}" "${fw}/Versions/A/Alembic"
    chmod +w "${fw}/Versions/A/Alembic"
    install_name_tool -id "@rpath/Alembic.framework/Versions/A/Alembic" \
        "${fw}/Versions/A/Alembic"

    local dylib_base soversion
    dylib_base="$(basename "${dylib_real}")"
    soversion="$(echo "${dylib_base}" | sed -E 's/^libAlembic\.([0-9]+).*\.dylib$/\1/')"
    ( cd "${fw}/Versions/A" && \
        ln -sf Alembic "libAlembic.${soversion}.dylib" && \
        ln -sf Alembic "libAlembic.dylib" )

    stage_headers "${fw}/Versions/A/Headers" "${install_dir}/include" "${IMATH_PREFIX}/include"
    cp "${ROOT}/resources/module.modulemap" "${fw}/Versions/A/Modules/module.modulemap"

    write_macos_info_plist "${fw}/Versions/A/Resources/Info.plist"

    local license_src
    license_src="$(find "${SRC_DIR}" -maxdepth 1 -type f -iname 'license*' | head -1)"
    if [ -n "${license_src}" ]; then
        cp "${license_src}" "${fw}/Versions/A/Resources/LICENSE.txt"
    fi

    # dylibbundler + rpath fixup
    local search_flags=()
    for p in ${DYLIBBUNDLER_SEARCH_PATHS}; do
        [ -d "$p" ] && search_flags+=("-s" "$p")
    done
    ( cd "${STAGE_ROOT}/${slice}" && \
        dylibbundler -od -b -x "./Alembic.framework/Versions/A/Alembic" \
            -d "./Alembic.framework/Versions/A/Libraries/" \
            -p "@loader_path/Libraries/" \
            "${search_flags[@]}" )

    dedupe_rpath() {
        local target="$1" path="$2" count
        count=$(otool -l "$target" | grep -c "path ${path} " || true)
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        while [ "$count" -gt 1 ]; do
            install_name_tool -delete_rpath "$path" "$target" 2>/dev/null || break
            count=$(otool -l "$target" | grep -c "path ${path} " || true)
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
        done
    }
    dedupe_rpath "${fw}/Versions/A/Alembic" "@loader_path/Libraries/"

    for lib in "${fw}/Versions/A/Libraries/"*.dylib; do
        [ -e "$lib" ] || continue
        dedupe_rpath "$lib" "@loader_path/Libraries/"
        local count
        count=$(otool -l "$lib" | grep -c "cmd LC_RPATH" || true)
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        if [ "$count" -eq 0 ]; then
            install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
        fi
        otool -L "$lib" | awk '/@loader_path\/Libraries\//{print $1}' | while read -r dep; do
            local libname; libname="$(basename "$dep")"
            install_name_tool -change "$dep" "@loader_path/$libname" "$lib" 2>/dev/null || true
        done
    done

    # Top-level symlinks
    ( cd "${fw}/Versions" && ln -sfn A Current )
    ( cd "${fw}" && \
        ln -sfn Versions/Current/Alembic Alembic && \
        ln -sfn Versions/Current/Headers Headers && \
        ln -sfn Versions/Current/Modules Modules && \
        ln -sfn Versions/Current/Libraries Libraries && \
        ln -sfn Versions/Current/Resources Resources )

    # Optional codesign
    local sign_id="${CODESIGN_IDENTITY:--}"
    echo "macOS codesign identity: ${sign_id}"
    find "${fw}/Versions/A" -type f \( -name "*.dylib" -o -name "Alembic" \) \
        -exec codesign --force --sign "${sign_id}" --timestamp=none {} \;
    codesign --force --sign "${sign_id}" --timestamp=none --deep "${fw}"
}

assemble_static_framework() {
    local slice="$1"
    local install_dir="${WORK}/${slice}/install"
    local imath_install="${WORK}/${slice}/imath-install"
    local fw="${STAGE_ROOT}/${slice}/Alembic.framework"
    rm -rf "${fw}"
    mkdir -p "${fw}/Headers" "${fw}/Modules"

    # Merge Alembic + Imath static archives into a single framework binary.
    local alembic_a
    alembic_a="$(find "${install_dir}/lib" -maxdepth 1 -name "libAlembic*.a" -type f | head -1)"
    if [ -z "${alembic_a}" ]; then
        echo "Could not locate libAlembic*.a in ${install_dir}/lib" >&2
        ls -la "${install_dir}/lib" >&2 || true
        exit 1
    fi
    local imath_as=()
    while IFS= read -r a; do imath_as+=("$a"); done < <(find "${imath_install}/lib" -maxdepth 1 -name "*.a" -type f | sort)
    if [ "${#imath_as[@]}" -eq 0 ]; then
        echo "Could not locate Imath .a files in ${imath_install}/lib" >&2
        ls -la "${imath_install}/lib" >&2 || true
        exit 1
    fi
    libtool -static -o "${fw}/Alembic" "${alembic_a}" "${imath_as[@]}"

    stage_headers "${fw}/Headers" "${install_dir}/include" "${imath_install}/include"
    cp "${ROOT}/resources/module.modulemap" "${fw}/Modules/module.modulemap"
    write_static_info_plist "${fw}/Info.plist" "${slice}"

    local license_src
    license_src="$(find "${SRC_DIR}" -maxdepth 1 -type f -iname 'license*' | head -1)"
    if [ -n "${license_src}" ]; then
        cp "${license_src}" "${fw}/LICENSE.txt"
    fi
}

# ----------------------------------------------------------------------------
# Phase 1: fetch
# ----------------------------------------------------------------------------
step "1/5  Fetch sources"
fetch_alembic
fetch_imath

# ----------------------------------------------------------------------------
# Phase 2: build slices
# ----------------------------------------------------------------------------
step "2/5  Build per-slice Imath (static, non-macOS)"
for slice in ${PLATFORMS}; do
    [ "${slice}" = "macos" ] && continue
    step "    Imath → ${slice}"
    build_imath_static "${slice}"
done

step "3/5  Build per-slice Alembic"
for slice in ${PLATFORMS}; do
    step "    Alembic → ${slice}"
    build_alembic "${slice}"
done

# ----------------------------------------------------------------------------
# Phase 3: assemble frameworks
# ----------------------------------------------------------------------------
step "4/5  Assemble frameworks"
for slice in ${PLATFORMS}; do
    step "    framework → ${slice}"
    if [ "${slice}" = "macos" ]; then
        assemble_macos_framework
    else
        assemble_static_framework "${slice}"
    fi
done

# ----------------------------------------------------------------------------
# Phase 4: wrap into xcframework
# ----------------------------------------------------------------------------
step "5/5  Wrap in xcframework + zip"
XC_OUT="${OUTPUT_DIR}/Alembic.xcframework"
rm -rf "${XC_OUT}"

xc_args=()
for slice in ${PLATFORMS}; do
    xc_args+=(-framework "${STAGE_ROOT}/${slice}/Alembic.framework")
done
xcodebuild -create-xcframework "${xc_args[@]}" -output "${XC_OUT}"

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
