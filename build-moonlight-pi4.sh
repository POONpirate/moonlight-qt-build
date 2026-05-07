#!/bin/bash
# =============================================================================
# Moonlight-Qt Build Script for Raspberry Pi 4
# Fixes "corrupted size vs. prev_size" runtime heap corruption by disabling
# the MMAL decoder (known buggy on Pi 4) and using V4L2 M2M instead.
# =============================================================================

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$REPO_DIR/build-pi4"

echo "============================================="
echo " Moonlight-Qt Pi 4 Build Script"
echo "============================================="
echo ""

# Prompt for sudo password upfront so it doesn't interrupt the build later.
# The background loop refreshes the credentials every 60s so they don't
# expire during a long compile.
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# -----------------------------------------------------------------------------
# Prep. Check we're on a Pi
# -----------------------------------------------------------------------------
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    echo "[WARNING] This doesn't look like a Raspberry Pi."
    echo "          Proceeding anyway, but results may vary."
    echo ""
fi

# -----------------------------------------------------------------------------
# 1. Locate or clone the moonlight-qt repository
# -----------------------------------------------------------------------------
echo "[1/6] Locating repository..."
if [ ! -f "$REPO_DIR/moonlight-qt.pro" ]; then
    echo "    No moonlight-qt.pro found in the script's directory."
    echo "Please choose a repository to clone, or exit and place this"
    echo "script inside an existing moonlight-qt source directory."
    echo ""

    # Ensure git is available before trying to clone
    if ! command -v git &>/dev/null; then
        echo "Installing git..."
        sudo apt-get update -q
        sudo apt-get install -y git
    fi

    PS3="Enter choice: "
    select REPO_CHOICE in \
        "moonlight-qt (official)  — https://github.com/moonlight-stream/moonlight-qt.git" \
        "moonlight-qt-mic (fork)  — https://github.com/logabell/moonlight-qt-mic" \
        "Exit"
    do
        case $REPLY in
            1)
                CLONE_URL="https://github.com/moonlight-stream/moonlight-qt.git"
                CLONE_DIR="$REPO_DIR/moonlight-qt"
                break
                ;;
            2)
                CLONE_URL="https://github.com/logabell/moonlight-qt-mic"
                CLONE_DIR="$REPO_DIR/moonlight-qt-mic"
                break
                ;;
            3)
                echo ""
                echo "Exiting. To use this script, either:"
                echo "  1) Place it inside an existing moonlight-qt source directory, or"
                echo "  2) Re-run it from any directory and choose a clone option."
                exit 0
                ;;
            *)
                echo "Invalid choice, please enter 1, 2, or 3."
                ;;
        esac
    done

    echo ""
    echo "Cloning $CLONE_URL into $CLONE_DIR ..."
    git clone "$CLONE_URL" "$CLONE_DIR"
    REPO_DIR="$CLONE_DIR"
    BUILD_DIR="$REPO_DIR/build-pi4"
    echo "    Done."
    echo ""
else
    echo "    Found moonlight-qt.pro. Continuing."
fi
echo ""

# -----------------------------------------------------------------------------
# 2. Install dependencies
# -----------------------------------------------------------------------------
echo "[2/6] Installing build dependencies..."
sudo apt-get update -q
sudo apt-get install -y \
    git \
    build-essential \
    libegl1-mesa-dev \
    libgl1-mesa-dev \
    libopus-dev \
    libsdl2-dev \
    libsdl2-ttf-dev \
    libssl-dev \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    libva-dev \
    libxkbcommon-dev \
    wayland-protocols \
    libdrm-dev \
    libgbm-dev \
    qt6-base-dev \
    qt6-declarative-dev \
    libqt6svg6 \
    libqt6svg6-dev \
    qt6-svg-plugins \
    qt6-wayland \
    qml6-module-qtquick-controls \
    qml6-module-qtquick-templates \
    qml6-module-qtquick-layouts \
    qml6-module-qtqml-workerscript \
    qml6-module-qtquick-window \
    qml6-module-qtquick 2>&1 | grep -E "(Reading|Building|Setting|Unpacking|Selecting|ERROR|error)" || true

echo "    Done."
echo ""

# -----------------------------------------------------------------------------
# 3. Initialize submodules
# -----------------------------------------------------------------------------
echo "[3/6] Initializing git submodules..."
cd "$REPO_DIR"
git submodule update --init --recursive
echo "    Done."
echo ""

# -----------------------------------------------------------------------------
# 4. Configure with qmake
#    - CONFIG+=disable-mmal: prevents MMAL renderer from being compiled in,
#      which is the source of the "corrupted size vs. prev_size" heap
#      corruption on Pi 4. V4L2 M2M hardware decoding (via FFmpeg) is used.
#    - CONFIG+=gpuslow: marks GL and Vulkan as slow, so the DRM/KMS renderer
#      is preferred over EGL/OpenGL — the better path on Pi 4.
#    - disable-wayland: auto-detected based on OS version (see below).
#      Bookworm (Pi OS 12) uses Wayland by default, earlier versions use X11.
# -----------------------------------------------------------------------------
echo "[4/6] Detecting OS and configuring qmake..."

# Detect whether to disable Wayland based on OS version
OS_VERSION=$(grep "^VERSION_ID" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
if [ -z "$OS_VERSION" ] || [ "$OS_VERSION" -lt 12 ] 2>/dev/null; then
    WAYLAND_FLAG="CONFIG+=disable-wayland"
    echo "    OS version ${OS_VERSION:-unknown} detected — disabling Wayland (X11 default)."
else
    WAYLAND_FLAG=""
    echo "    OS version ${OS_VERSION} detected — keeping Wayland support enabled."
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Set architecture-appropriate CPU flag
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    ARCH_FLAG='QMAKE_CXXFLAGS+=-march=armv8-a+crc+simd'
    echo "    64-bit (aarch64) detected."
else
    # 32-bit armhf — Pi 4 hardware is ARMv8 but running in 32-bit mode
    ARCH_FLAG='QMAKE_CXXFLAGS+=-march=armv8-a+crc'
    echo "    32-bit (armhf) detected."
fi

qmake6 "$REPO_DIR/moonlight-qt.pro" \
    CONFIG+=disable-mmal \
    CONFIG+=gpuslow \
    $WAYLAND_FLAG \
    "$ARCH_FLAG" \
    2>&1

echo "    Done."
echo ""

# -----------------------------------------------------------------------------
# 5. Build (limit parallel jobs to avoid OOM on low-RAM Pi 4 models).
#    The project uses CONFIG+=debug_and_release, so we use "make release"
#    rather than passing CONFIG+=release to qmake.
# -----------------------------------------------------------------------------
RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
echo "[5/6] Building release target (detected ~${RAM_MB} MB RAM)..."
if [ "$RAM_MB" -ge 3500 ]; then
    JOBS=4
elif [ "$RAM_MB" -ge 1800 ]; then
    JOBS=2
else
    JOBS=1
    echo "    [!] Low RAM detected — using single-threaded build to prevent crashes."
fi
echo "    Using -j${JOBS}"
make -j${JOBS} release
echo "    Done."
echo ""

# -----------------------------------------------------------------------------
# 6. Summary
# -----------------------------------------------------------------------------
echo "[6/6] Build complete!"
echo ""
echo "Binary location: $BUILD_DIR/app/moonlight"
echo ""
echo "To install system-wide:"
echo "  sudo cp $BUILD_DIR/app/moonlight /usr/local/bin/moonlight-qt"
echo ""
echo "To run directly:"
echo "  $BUILD_DIR/app/moonlight"
echo ""
echo "NOTE: If you still see hardware decode issues, you can force software"
echo "decoding by launching with:"
echo "  MOONLIGHT_FORCE_SW_DECODE=1 $BUILD_DIR/app/moonlight"
echo ""
