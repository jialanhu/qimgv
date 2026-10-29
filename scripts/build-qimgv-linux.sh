#!/usr/bin/env bash
#
# build-qimgv-linux.sh - cross-compile qimgv for 64-bit Windows on Linux.
#
# This is the Linux counterpart of scripts/build-qimgv.sh (which runs inside
# MSYS2 on Windows). It uses a MinGW-w64 cross toolchain and a Qt 6.12 build
# for the Windows target. The recommended way to get all of that is MXE:
#
#   git clone https://github.com/mxe/mxe.git "$HOME/mxe"
#   make -C "$HOME/mxe" MXE_TARGETS=x86_64-w64-mingw32.shared \
#        qt6-qtbase qt6-qtsvg qt6-qttools qt6-qtimageformats exiv2 opencv
#   ./scripts/build-qimgv-linux.sh --package
#
# If Exiv2, OpenCV or libmpv is not available, the corresponding feature is
# disabled automatically. Use --no-exiv2/--no-opencv/--no-video to disable
# explicitly, or --minimal to build with Qt only.
#
# Unlike scripts/build-qimgv.sh, this does not build the optional third-party
# imageformat plugins (JPEG XL, AVIF, APNG, HEIF, RAW). qimgv itself and the
# mpv player plugin are built.
#
# Usage:
#   ./scripts/build-qimgv-linux.sh [options]
#
# Options:
#   -j, --jobs N       Number of parallel compile jobs (default: nproc)
#   --clean            Delete the build directory before configuring
#   --debug            Build with CMAKE_BUILD_TYPE=Debug
#   --minimal          Disable Exiv2, OpenCV and video support
#   --no-exiv2         Disable Exiv2 support
#   --no-opencv        Disable OpenCV support
#   --no-video         Disable the libmpv video plugin
#   --package          Create a portable Windows folder (default)
#   --no-package       Only build, do not create a portable Windows folder
#   --zip              Also create a .zip archive of the portable folder
#   --static           Use an MXE static Qt target (advanced; see warning)
#   -h, --help         Show this help
#
# Environment:
#   MINGW_PREFIX       Windows sysroot, e.g. /usr/x86_64-w64-mingw32
#                      (auto-detected from MXE if not set)
#   MXE_DIR            MXE installation prefix (default: /opt/mxe, ~/mxe)
#   MXE_TARGET         MXE target, e.g. x86_64-w64-mingw32.shared
#   MPV_DIR            Windows libmpv tree (include/mpv + lib/libmpv.dll.a)
#                      Auto-detected from the sysroot/MXE if available
#   BUILD_DIR          Build directory (default: <source>/build-win64)
#   JOBS               Default number of parallel jobs
#
# Examples:
#   ./scripts/build-qimgv-linux.sh
#   ./scripts/build-qimgv-linux.sh --minimal -j 8
#   MXE_DIR=/opt/mxe ./scripts/build-qimgv-linux.sh --clean --zip
#   MPV_DIR=/path/to/mingw64 ./scripts/build-qimgv-linux.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC_DIR="$(dirname -- "$SCRIPT_DIR")"
VERSION="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || echo "1.0.2")"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
BUILD_TYPE="Release"
DO_CLEAN=0
DO_PACKAGE=1
DO_ZIP=0
PREFER_STATIC=0

WITH_EXIV2="auto"
WITH_OPENCV="auto"
WITH_VIDEO="auto"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

note() {
    printf '==> %s\n' "$*"
}

usage() {
    sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

while (($# > 0)); do
    case "$1" in
        -j|--jobs)
            [[ $# -ge 2 ]] || die "$1 requires an argument"
            JOBS="$2"
            shift 2
            ;;
        --jobs=*)
            JOBS="${1#*=}"
            shift
            ;;
        --clean)
            DO_CLEAN=1
            shift
            ;;
        --debug)
            BUILD_TYPE="Debug"
            shift
            ;;
        --minimal)
            WITH_EXIV2="off"
            WITH_OPENCV="off"
            WITH_VIDEO="off"
            shift
            ;;
        --no-exiv2)
            WITH_EXIV2="off"
            shift
            ;;
        --no-opencv)
            WITH_OPENCV="off"
            shift
            ;;
        --no-video)
            WITH_VIDEO="off"
            shift
            ;;
        --package)
            DO_PACKAGE=1
            shift
            ;;
        --no-package)
            DO_PACKAGE=0
            shift
            ;;
        --zip)
            DO_ZIP=1
            shift
            ;;
        --static)
            PREFER_STATIC=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (use --help)"
            ;;
    esac
done

[[ "$JOBS" =~ ^[0-9]+$ ]] && ((JOBS > 0)) || die "invalid job count: $JOBS"

for tool in cmake ninja; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required but was not found in PATH"
done

if [[ -z "${BUILD_DIR:-}" ]]; then
    BUILD_DIR="$SRC_DIR/build-win64"
fi
BUILD_DIR="$(mkdir -p "$(dirname -- "$BUILD_DIR")" && cd -- "$(dirname -- "$BUILD_DIR")" && pwd -P)/$(basename -- "$BUILD_DIR")"

# ------------------------------------------------------------------------------
# Locate a MinGW-w64 toolchain + Windows Qt installation.
#
# We support two layouts:
#   1. MXE:  <mxe>/usr/<target>/ (Qt in <mxe>/usr/<target>/qt6)
#   2. Distro cross packages: /usr/x86_64-w64-mingw32 (Qt in .../qt6 or ...)
# ------------------------------------------------------------------------------
CROSS_PREFIX=""
CROSS_BIN=""
CROSS_SUFFIX=""
QT_ROOT=""
MXE_ROOT=""
MXE_TARGET=""

find_mxe() {
    local root target
    local -a roots=()

    if [[ -n "${MXE_DIR:-}" ]]; then
        roots+=("$MXE_DIR")
    else
        roots+=("/opt/mxe" "/usr/lib/mxe")
        [[ -n "${HOME:-}" ]] && roots+=("$HOME/mxe" "$HOME/.local/mxe")
    fi

    for root in "${roots[@]}"; do
        [[ -d "$root/usr" ]] || continue

        local -a targets=()
        if [[ -n "${MXE_TARGET:-}" ]]; then
            targets+=("$MXE_TARGET")
        fi
        if ((PREFER_STATIC)); then
            targets+=("x86_64-w64-mingw32.static" "x86_64-w64-mingw32.shared")
        else
            targets+=("x86_64-w64-mingw32.shared" "x86_64-w64-mingw32.static")
        fi

        for target in "${targets[@]}"; do
            if [[ -x "$root/usr/bin/$target-g++" && -d "$root/usr/$target/qt6" ]]; then
                MXE_ROOT="$root"
                MXE_TARGET="$target"
                CROSS_PREFIX="$root/usr/$target"
                CROSS_BIN="$root/usr/bin"
                CROSS_SUFFIX="$target"
                QT_ROOT="$root/usr/$target/qt6"
                return 0
            fi
        done
    done
    return 1
}

find_distro_prefix() {
    local prefix
    local -a prefixes=()
    if [[ -n "${MINGW_PREFIX:-}" ]]; then
        prefixes+=("$MINGW_PREFIX")
    else
        prefixes+=("/usr/x86_64-w64-mingw32" "/usr/local/x86_64-w64-mingw32")
    fi

    for prefix in "${prefixes[@]}"; do
        [[ -d "$prefix" ]] || continue
        if [[ -d "$prefix/qt6" ]]; then
            CROSS_PREFIX="$prefix"
            CROSS_SUFFIX="x86_64-w64-mingw32"
            QT_ROOT="$prefix/qt6"
        elif [[ -f "$prefix/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
            CROSS_PREFIX="$prefix"
            CROSS_SUFFIX="x86_64-w64-mingw32"
            QT_ROOT="$prefix"
        else
            continue
        fi

        if [[ -x "$(command -v "$CROSS_SUFFIX-g++" 2>/dev/null || true)" ]]; then
            CROSS_BIN="$(dirname -- "$(command -v "$CROSS_SUFFIX-g++")")"
        elif [[ -x "$CROSS_PREFIX/bin/$CROSS_SUFFIX-g++" ]]; then
            CROSS_BIN="$CROSS_PREFIX/bin"
        else
            continue
        fi
        return 0
    done
    return 1
}

if [[ -n "${MINGW_PREFIX:-}" && -z "${MXE_DIR:-}" ]]; then
    find_distro_prefix || die "MINGW_PREFIX=$MINGW_PREFIX does not contain a MinGW Qt 6.12 installation"
elif ! find_mxe; then
    if ! find_distro_prefix; then
        cat >&2 <<EOF
error: no Windows Qt 6.12 installation for MinGW-w64 was found.

Install MXE and build the needed packages (this is the recommended setup):

    git clone https://github.com/mxe/mxe.git "\$HOME/mxe"
    make -C "\$HOME/mxe" MXE_TARGETS=x86_64-w64-mingw32.shared \\
         qt6-qtbase qt6-qtsvg qt6-qttools qt6-qtimageformats exiv2 opencv

Then run this script again:

    ./scripts/build-qimgv-linux.sh --package

For a quick Qt-only build:

    make -C "\$HOME/mxe" MXE_TARGETS=x86_64-w64-mingw32.shared qt6-qtbase qt6-qtsvg qt6-qttools
    ./scripts/build-qimgv-linux.sh --minimal

Alternatively, point MINGW_PREFIX at a sysroot that has a Windows Qt 6.12
build for MinGW-w64, for example an Arch Linux mingw-w64 cross prefix:

    MINGW_PREFIX=/usr/x86_64-w64-mingw32 ./scripts/build-qimgv-linux.sh
EOF
        exit 1
    fi
fi

CROSS_PREFIX="$(cd -- "$CROSS_PREFIX" && pwd -P)"
QT_ROOT="$(cd -- "$QT_ROOT" && pwd -P)"
CROSS_BIN="$(cd -- "$CROSS_BIN" && pwd -P)"
[[ -n "$MXE_ROOT" ]] && MXE_ROOT="$(cd -- "$MXE_ROOT" && pwd -P)"

CROSS_GCC="$CROSS_BIN/${CROSS_SUFFIX}-gcc"
CROSS_GXX="$CROSS_BIN/${CROSS_SUFFIX}-g++"
CROSS_RC="$CROSS_BIN/${CROSS_SUFFIX}-windres"
CROSS_OBJDUMP="$CROSS_BIN/${CROSS_SUFFIX}-objdump"

for tool in "$CROSS_GCC" "$CROSS_GXX" "$CROSS_RC"; do
    [[ -x "$tool" ]] || die "required MinGW-w64 tool not found: $tool"
done

if [[ ! -x "$CROSS_OBJDUMP" ]]; then
    if [[ -x "$CROSS_BIN/x86_64-w64-mingw32-objdump" ]]; then
        CROSS_OBJDUMP="$CROSS_BIN/x86_64-w64-mingw32-objdump"
    elif command -v objdump >/dev/null 2>&1; then
        CROSS_OBJDUMP="$(command -v objdump)"
    else
        die "objdump not found (needed to collect DLL dependencies)"
    fi
fi

TRIPLET="${CROSS_SUFFIX%%.*}"
CROSS_GCC_REAL="$(readlink -f -- "$CROSS_GCC" 2>/dev/null || printf '%s' "$CROSS_GCC")"

if [[ ! -f "$QT_ROOT/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
    die "no Qt 6.12 CMake package found under $QT_ROOT"
fi

# qimgv's translation targets need Qt6 LinguistTools and lrelease even if
# translations are not interesting for a local build.
if [[ ! -d "$QT_ROOT/lib/cmake/Qt6LinguistTools" ]]; then
    die "Qt6 LinguistTools not found under $QT_ROOT; install the MXE qt6-qttools package"
fi

note "MinGW-w64: $CROSS_PREFIX"
note "Qt:        $QT_ROOT"
if [[ -n "$MXE_ROOT" ]]; then
    note "MXE:       $MXE_ROOT ($MXE_TARGET)"
fi

if [[ "$CROSS_SUFFIX" == *.static || "$QT_ROOT" == *static* ]]; then
    warn "static Qt target detected. qimgv does not link the Qt platform plugin"
    warn "into the executable, so the resulting qimgv.exe may fail to start."
    warn "Use the x86_64-w64-mingw32.shared MXE target for a portable build."
fi

# ------------------------------------------------------------------------------
# Prepare build directory and a cross pkg-config wrapper.
# ------------------------------------------------------------------------------
if ((DO_CLEAN)); then
    note "Cleaning $BUILD_DIR"
    rm -rf -- "$BUILD_DIR"
fi
mkdir -p -- "$BUILD_DIR"

if [[ -x "$CROSS_BIN/${CROSS_SUFFIX}-pkg-config" ]]; then
    CROSS_PKG_CONFIG="$CROSS_BIN/${CROSS_SUFFIX}-pkg-config"
elif [[ -x "$CROSS_PREFIX/bin/${CROSS_SUFFIX}-pkg-config" ]]; then
    CROSS_PKG_CONFIG="$CROSS_PREFIX/bin/${CROSS_SUFFIX}-pkg-config"
else
    CROSS_PKG_CONFIG="$BUILD_DIR/cross-pkg-config"
    cat > "$CROSS_PKG_CONFIG" <<EOF
#!/usr/bin/env bash
# Generated by build-qimgv-linux.sh
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$CROSS_PREFIX/lib/pkgconfig:$CROSS_PREFIX/share/pkgconfig:$QT_ROOT/lib/pkgconfig"
unset PKG_CONFIG_SYSROOT_DIR
exec pkg-config "\$@"
EOF
    chmod +x "$CROSS_PKG_CONFIG"
fi

# Keep CMake's FindPkgConfig away from the host's .pc files.
export PKG_CONFIG_PATH="$CROSS_PREFIX/lib/pkgconfig:$CROSS_PREFIX/share/pkgconfig:$QT_ROOT/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
unset PKG_CONFIG_SYSROOT_DIR || true

# ------------------------------------------------------------------------------
# Detect optional dependencies.
# ------------------------------------------------------------------------------
have_pkg() {
    "$CROSS_PKG_CONFIG" --exists "$1" 2>/dev/null
}

if [[ "$WITH_EXIV2" == "auto" ]]; then
    if have_pkg exiv2; then
        WITH_EXIV2="on"
    else
        WITH_EXIV2="off"
        warn "Exiv2 not found for the Windows target; building without EXIF support"
    fi
fi

OPENCV_DIR=""
if [[ "$WITH_OPENCV" == "auto" ]]; then
    OPENCV_DIR="$(find "$CROSS_PREFIX" -maxdepth 5 -name OpenCVConfig.cmake -print -quit 2>/dev/null || true)"
    if [[ -n "$OPENCV_DIR" ]]; then
        WITH_OPENCV="on"
        OPENCV_DIR="$(dirname -- "$OPENCV_DIR")"
    else
        WITH_OPENCV="off"
        warn "OpenCV not found for the Windows target; building without OpenCV support"
    fi
elif [[ "$WITH_OPENCV" == "on" && -z "${OPENCV_DIR:-}" ]]; then
    OPENCV_DIR="$(find "$CROSS_PREFIX" -maxdepth 5 -name OpenCVConfig.cmake -print -quit 2>/dev/null || true)"
    OPENCV_DIR="${OPENCV_DIR:+$(dirname -- "$OPENCV_DIR")}"
fi

# The qimgv player plugin expects ${MPV_DIR}/include and ${MPV_DIR}/lib/x86_64.
# Normalize whatever Windows libmpv tree the user has into that layout. This
# also creates libMpv.dll.a, because the linker on a case-sensitive Linux
# filesystem would otherwise not find libmpv.dll.a for "-lMpv".
MPV_STAGE=""
if [[ "$WITH_VIDEO" == "auto" || "$WITH_VIDEO" == "on" ]]; then
    MPV_SOURCE="${MPV_DIR:-}"
    if [[ -z "$MPV_SOURCE" ]]; then
        for candidate in "$CROSS_PREFIX" "$QT_ROOT"; do
            if [[ -f "$candidate/include/mpv/client.h" ]]; then
                MPV_SOURCE="$candidate"
                break
            fi
        done
    fi

    if [[ -n "$MPV_SOURCE" && -d "$MPV_SOURCE" ]]; then
        MPV_SOURCE="$(cd -- "$MPV_SOURCE" && pwd -P)"
    fi
    if [[ -n "$MPV_SOURCE" && -f "$MPV_SOURCE/include/mpv/client.h" ]]; then
        MPV_LIB="$(find "$MPV_SOURCE" -maxdepth 4 \
            \( -name 'libmpv.dll.a' -o -name 'libmpv.a' -o -name 'mpv.lib' \) \
            -print -quit 2>/dev/null || true)"
        if [[ -n "$MPV_LIB" ]]; then
            MPV_STAGE="$BUILD_DIR/mpv"
            rm -rf -- "$MPV_STAGE"
            mkdir -p "$MPV_STAGE/include" "$MPV_STAGE/lib/x86_64"
            ln -s "$MPV_SOURCE/include/mpv" "$MPV_STAGE/include/mpv"
            case "$(basename -- "$MPV_LIB")" in
                libmpv.dll.a|mpv.lib) ln -s "$MPV_LIB" "$MPV_STAGE/lib/x86_64/libMpv.dll.a" ;;
                libmpv.a)             ln -s "$MPV_LIB" "$MPV_STAGE/lib/x86_64/libMpv.a" ;;
            esac
            WITH_VIDEO="on"
        elif [[ "$WITH_VIDEO" == "on" ]]; then
            die "libmpv library not found under $MPV_SOURCE"
        else
            WITH_VIDEO="off"
            warn "libmpv headers found but no import library; building without video support"
        fi
    elif [[ "$WITH_VIDEO" == "on" ]]; then
        die "MPV_DIR must point to a Windows libmpv tree containing include/mpv/client.h"
    else
        WITH_VIDEO="off"
        warn "Windows libmpv not found; building without video support (set MPV_DIR to enable)"
    fi
fi

note "Features:  Exiv2=$WITH_EXIV2 OpenCV=$WITH_OPENCV Video=$WITH_VIDEO"

# ------------------------------------------------------------------------------
# Generate a CMake toolchain file when an MXE cmake wrapper is not available.
# ------------------------------------------------------------------------------
TOOLCHAIN_FILE="$BUILD_DIR/mingw-w64-toolchain.cmake"
cat > "$TOOLCHAIN_FILE" <<EOF
# Generated by scripts/build-qimgv-linux.sh
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_VERSION 10)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER   "$CROSS_GCC")
set(CMAKE_CXX_COMPILER "$CROSS_GXX")
set(CMAKE_RC_COMPILER  "$CROSS_RC")

set(CMAKE_FIND_ROOT_PATH "$CROSS_PREFIX" "$QT_ROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_PREFIX_PATH "$CROSS_PREFIX" "$QT_ROOT")
set(CMAKE_MODULE_PATH "$CROSS_PREFIX/share/cmake" "\${CMAKE_MODULE_PATH}")

set(PKG_CONFIG_EXECUTABLE "$CROSS_PKG_CONFIG" CACHE FILEPATH "Cross pkg-config")
set(CMAKE_EXPORT_NO_PACKAGE_REGISTRY ON)
EOF

# Qt 6 cross builds need host tools in addition to the target libraries. MXE's
# cmake wrapper sets QT_HOST_PATH itself; the generated toolchain above needs
# an explicit value.
QT_HOST_PATH=""
if [[ -n "$MXE_ROOT" && -d "$MXE_ROOT/usr/x86_64-pc-linux-gnu/qt6" ]]; then
    QT_HOST_PATH="$MXE_ROOT/usr/x86_64-pc-linux-gnu/qt6"
    printf 'set(QT_HOST_PATH "%s" CACHE PATH "Qt6 host tools")\n' "$QT_HOST_PATH" >> "$TOOLCHAIN_FILE"
fi

# ------------------------------------------------------------------------------
# Configure and build.
# ------------------------------------------------------------------------------
CMAKE_ARGS=(
    -S "$SRC_DIR"
    -B "$BUILD_DIR"
    -G Ninja
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DCMAKE_PREFIX_PATH="$CROSS_PREFIX;$QT_ROOT"
    -DUSE_QT5=OFF
    -DEXIV2="$([[ "$WITH_EXIV2" == "on" ]] && echo ON || echo OFF)"
    -DOPENCV_SUPPORT="$([[ "$WITH_OPENCV" == "on" ]] && echo ON || echo OFF)"
    -DVIDEO_SUPPORT="$([[ "$WITH_VIDEO" == "on" ]] && echo ON || echo OFF)"
    -DPKG_CONFIG_EXECUTABLE="$CROSS_PKG_CONFIG"
)

if [[ "$WITH_OPENCV" == "on" && -n "$OPENCV_DIR" ]]; then
    CMAKE_ARGS+=(-DOpenCV_DIR="$OPENCV_DIR")
fi
if [[ "$WITH_VIDEO" == "on" && -n "$MPV_STAGE" ]]; then
    CMAKE_ARGS+=(-DMPV_DIR="$MPV_STAGE")
fi

if [[ -n "$MXE_ROOT" && -x "$MXE_ROOT/usr/bin/${MXE_TARGET}-cmake" ]]; then
    CMAKE_CMD=("$MXE_ROOT/usr/bin/${MXE_TARGET}-cmake")
else
    CMAKE_CMD=(cmake)
    CMAKE_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE")
fi

note "Configuring"
"${CMAKE_CMD[@]}" "${CMAKE_ARGS[@]}"

note "Building with $JOBS job(s)"
cmake --build "$BUILD_DIR" --parallel "$JOBS"

EXE="$BUILD_DIR/qimgv/qimgv.exe"
[[ -f "$EXE" ]] || die "build finished without producing $EXE"

if command -v file >/dev/null 2>&1; then
    file "$EXE"
fi
note "Windows executable: $EXE"

# ------------------------------------------------------------------------------
# Create a portable Windows folder.
# ------------------------------------------------------------------------------
is_system_dll() {
    case "${1,,}" in
        api-ms-win-*|ext-ms-*|kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|\
        shell32.dll|shlwapi.dll|ole32.dll|oleaut32.dll|uuid.dll|comdlg32.dll|\
        comctl32.dll|ws2_32.dll|mswsock.dll|winmm.dll|imm32.dll|version.dll|\
        mpr.dll|netapi32.dll|userenv.dll|psapi.dll|dbghelp.dll|powrprof.dll|\
        setupapi.dll|cfgmgr32.dll|winspool.drv|winspool.dll|shcore.dll|\
        shfolder.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|vcruntime*.dll|\
        msvcp*.dll|concrt*.dll|sechost.dll|bcrypt.dll|\
        ncrypt.dll|crypt32.dll|secur32.dll|sspicli.dll|iphlpapi.dll|\
        dnsapi.dll|wldap32.dll|normaliz.dll|winhttp.dll|wininet.dll|\
        urlmon.dll|oleacc.dll|propsys.dll|runtimeobject.dll|sensorsapi.dll|\
        portabledeviceapi.dll|avrt.dll|mf*.dll|evr.dll|\
        strmiids.dll|wmcodecdspuuid.dll|dxva2.dll|mscms.dll|icm32.dll|\
        d3d9.dll|d3d11.dll|dxgi.dll|opengl32.dll|glu32.dll|gdiplus.dll|\
        msimg32.dll|dwrite.dll|d2d1.dll|dcomp.dll|uxtheme.dll|dwmapi.dll|\
        wintrust.dll|wtsapi32.dll|winbio.dll|wevtapi.dll|wer.dll|\
        wlanapi.dll|winsta.dll|ntdsapi.dll|avicap32.dll|wsock32.dll|\
        msvfw32.dll|dsound.dll|dinput8.dll|xinput1_4.dll|hid.dll|\
        pdh.dll|credui.dll|authz.dll|wbemuuid.dll|cryptui.dll|\
        sensapi.dll|dhcpsapi.dll|imagehlp.dll|ntasn1.dll|cryptbase.dll|\
        msacm32.dll|winusb.dll|virtdisk.dll|wimgapi.dll)
            return 0
            ;;
    esac
    return 1
}

find_dll() {
    local name="$1" dir found
    local -a dirs=(
        "$CROSS_PREFIX/bin"
        "$QT_ROOT/bin"
        "$CROSS_PREFIX/lib"
        "$CROSS_BIN"
        "/usr/$TRIPLET/bin"
        "/usr/$TRIPLET/lib"
        "/usr/lib/gcc/$TRIPLET"
        "$CROSS_PREFIX/$CROSS_SUFFIX/bin"
        "$CROSS_PREFIX/$CROSS_SUFFIX/lib"
    )
    if [[ -n "$MXE_ROOT" ]]; then
        dirs+=("$MXE_ROOT/usr/$MXE_TARGET/bin")
    fi
    if [[ -n "${MPV_SOURCE:-}" ]]; then
        dirs+=("$MPV_SOURCE/bin" "$MPV_SOURCE/lib" "$MPV_SOURCE" \
               "$MPV_SOURCE/bin/x86_64" "$MPV_SOURCE/lib/x86_64")
    fi
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        if [[ -f "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
        found="$(find "$dir" -maxdepth 1 -type f -iname "$name" -print -quit 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            printf '%s\n' "$found"
            return 0
        fi
    done
    # MinGW runtime DLLs can live in the compiler's versioned lib directory.
    found="$(find "$(dirname -- "$CROSS_GCC_REAL")/../lib" -maxdepth 5 -type f -iname "$name" -print -quit 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi
    found="$(find "/usr/lib/gcc/$TRIPLET" -maxdepth 3 -type f -iname "$name" -print -quit 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi
    return 1
}

package_build() {
    local package_name="qimgv-win64_${VERSION}"
    PACKAGE_DIR="$SRC_DIR/$package_name"
    local missing=()
    local -a queue=()
    declare -A seen=()

    rm -rf -- "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR"/{cache,conf}

    cp "$EXE" "$PACKAGE_DIR/"
    queue+=("$PACKAGE_DIR/qimgv.exe")

    if [[ -d "$BUILD_DIR/qimgv/translations" ]]; then
        cp -r "$BUILD_DIR/qimgv/translations" "$PACKAGE_DIR/"
    fi

    if [[ "$WITH_VIDEO" == "on" ]]; then
        local player="$BUILD_DIR/plugins/player_mpv/player_mpv.dll"
        if [[ -f "$player" ]]; then
            mkdir -p "$PACKAGE_DIR/plugins"
            cp "$player" "$PACKAGE_DIR/plugins/"
            queue+=("$PACKAGE_DIR/plugins/player_mpv.dll")
        else
            warn "video plugin was enabled but player_mpv.dll was not built"
        fi
    fi

    if [[ -d "$SRC_DIR/qimgv/distrib/mimedata/data" ]]; then
        cp -r "$SRC_DIR/qimgv/distrib/mimedata/data" "$PACKAGE_DIR/"
    fi

    # mpv and libmpv are loaded dynamically by qimgv/player_mpv.dll, so they
    # are not found through qimgv.exe's import table. Add them to the DLL
    # dependency queue before resolving imports.
    if [[ "$WITH_VIDEO" == "on" && -n "${MPV_SOURCE:-}" ]]; then
        local f
        f="$(find "$MPV_SOURCE" -maxdepth 3 -type f -iname 'libmpv*.dll' -print -quit 2>/dev/null || true)"
        if [[ -n "$f" ]]; then
            cp -fL "$f" "$PACKAGE_DIR/"
            queue+=("$PACKAGE_DIR/$(basename -- "$f")")
        fi
        f="$(find "$MPV_SOURCE" -maxdepth 3 -type f -iname 'mpv.exe' -print -quit 2>/dev/null || true)"
        if [[ -n "$f" ]]; then
            cp -fL "$f" "$PACKAGE_DIR/"
            queue+=("$PACKAGE_DIR/mpv.exe")
        fi
    fi

    # Qt is dynamically linked only for MXE's "shared" target (or distro Qt
    # builds). Static Qt targets do not need the plugins or Qt DLLs.
    local qt_shared=0
    if compgen -G "$QT_ROOT/bin/Qt6Core*.dll" >/dev/null 2>&1 || \
       compgen -G "$CROSS_PREFIX/bin/Qt6Core*.dll" >/dev/null 2>&1; then
        qt_shared=1
    fi

    if ((qt_shared)); then
        local plugin_root="$QT_ROOT/plugins"
        [[ -d "$plugin_root" ]] || plugin_root="$CROSS_PREFIX/plugins"

        if [[ -d "$plugin_root" ]]; then
            local sub
            for sub in platforms imageformats iconengines styles printsupport; do
                [[ -d "$plugin_root/$sub" ]] || continue
                mkdir -p "$PACKAGE_DIR/$sub"
                if [[ "$sub" == "platforms" ]]; then
                    # Only the native Windows platform plugin is required.
                    if [[ -f "$plugin_root/$sub/qwindows.dll" ]]; then
                        cp -f "$plugin_root/$sub/qwindows.dll" "$PACKAGE_DIR/$sub/"
                    fi
                else
                    find "$plugin_root/$sub" -maxdepth 1 -type f -name '*.dll' \
                        -exec cp -f {} "$PACKAGE_DIR/$sub/" \;
                fi
                while IFS= read -r dll; do
                    queue+=("$dll")
                done < <(find "$PACKAGE_DIR/$sub" -maxdepth 1 -type f -name '*.dll' -print)
            done
        else
            warn "Qt plugin directory not found; qwindows.dll will be missing"
        fi

        # Qt may load these at runtime without importing them into qimgv.exe.
        local runtime_dll
        for runtime_dll in opengl32sw.dll libEGL.dll libGLESv2.dll d3dcompiler_47.dll; do
            local runtime_dir
            for runtime_dir in "$QT_ROOT/bin" "$CROSS_PREFIX/bin"; do
                if [[ -f "$runtime_dir/$runtime_dll" ]]; then
                    cp -f "$runtime_dir/$runtime_dll" "$PACKAGE_DIR/"
                    queue+=("$PACKAGE_DIR/$runtime_dll")
                    break
                fi
            done
        done
    fi

    # Copy DLLs by following the PE import table recursively.
    note "Collecting runtime DLLs"
    while ((${#queue[@]} > 0)); do
        local file="${queue[0]}"
        queue=("${queue[@]:1}")
        while IFS= read -r dll; do
            local key="${dll,,}"
            if [[ -n "${seen[$key]:-}" ]]; then
                continue
            fi
            seen[$key]=1

            if is_system_dll "$dll"; then
                continue
            fi

            local src
            if src="$(find_dll "$dll")"; then
                cp -fL "$src" "$PACKAGE_DIR/"
                queue+=("$PACKAGE_DIR/$(basename -- "$src")")
            else
                missing+=("$dll")
            fi
        done < <("$CROSS_OBJDUMP" -p "$file" 2>/dev/null | awk '/DLL Name:/ { print $3 }')
    done

    if ((${#missing[@]} > 0)); then
        local dll
        for dll in "${missing[@]}"; do
            warn "DLL not found in the MinGW/Qt tree: $dll (copy it manually if it is not a system DLL)"
        done
    fi

    note "Portable package: $PACKAGE_DIR"

    if ((DO_ZIP)); then
        command -v zip >/dev/null 2>&1 || die "zip not found (required by --zip)"
        rm -f "$SRC_DIR/${package_name}.zip"
        (cd "$SRC_DIR" && zip -qr "${package_name}.zip" "$package_name")
        note "Archive: $SRC_DIR/${package_name}.zip"
    fi
}

if ((DO_PACKAGE)); then
    package_build
fi

note "Done"
