#!/usr/bin/env bash
# Install dependencies for llama-swap on Jetson AGX Xavier (linux/arm64):
#   1. llama-swap binary (pinned release, downloaded)
#   2. llama-server binary (built from source against CUDA sm_72)
#
# Pins llama-swap to a specific version so this is reproducible. Bump VERSION
# below to upgrade and re-run.
set -euo pipefail

cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
BIN_DIR="$REPO_DIR/bin"
VENDOR_DIR="$REPO_DIR/vendor"

VERSION="216"
ASSET="llama-swap_${VERSION}_linux_arm64.tar.gz"
URL="https://github.com/mostlygeek/llama-swap/releases/download/v${VERSION}/${ASSET}"

# -----------------------------------------------------------------------------
# 1. llama-swap binary
# -----------------------------------------------------------------------------
install_llama_swap() {
    if [ -x ./llama-swap ]; then
        echo "llama-swap already installed:"
        ./llama-swap --version || ./llama-swap -version || true
        echo
        read -rp "Re-download and overwrite with v${VERSION}? [y/N] " yn
        [[ "${yn,,}" == "y" ]] || return 0
    fi

    echo "Downloading $URL"
    curl -fL "$URL" -o "/tmp/${ASSET}"

    echo "Extracting..."
    tar -xzf "/tmp/${ASSET}" -C /tmp llama-swap
    mv /tmp/llama-swap ./llama-swap
    chmod +x ./llama-swap
    rm -f "/tmp/${ASSET}"

    echo "Installed llama-swap:"
    ./llama-swap --version 2>/dev/null || ./llama-swap -version 2>/dev/null || echo "  (run with -h to inspect)"
}

# -----------------------------------------------------------------------------
# 2. llama-server (built from llama.cpp with CUDA for sm_72 / Volta)
# -----------------------------------------------------------------------------
install_llama_server() {
    mkdir -p "$BIN_DIR" "$VENDOR_DIR"
    local SRC="$VENDOR_DIR/llama.cpp"

    if [ -x "$BIN_DIR/llama-server" ]; then
        echo "llama-server already present at $BIN_DIR/llama-server"
        "$BIN_DIR/llama-server" --version 2>&1 | head -n 3 || true
        echo
        read -rp "Rebuild from source? [y/N] " yn
        [[ "${yn,,}" == "y" ]] || return 0
    else
        echo "llama-server not found at $BIN_DIR/llama-server"
        read -rp "Build it now from llama.cpp source? (takes a while) [Y/n] " yn
        [[ "${yn,,}" == "n" ]] && { echo "Skipping llama-server build."; return 0; }
    fi

    echo "[1/5] apt deps (sudo)"
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        build-essential cmake git ccache pkg-config curl ca-certificates \
        libcurl4-openssl-dev

    # JetPack ships nvcc at /usr/local/cuda/bin; expose it if needed.
    if ! command -v nvcc >/dev/null 2>&1; then
        for cand in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
            [ -x "$cand" ] && export PATH="$(dirname "$cand"):$PATH" && break
        done
    fi
    nvcc --version || { echo "nvcc not found; install CUDA from JetPack first." >&2; exit 1; }

    echo "[2/5] clone llama.cpp"
    if [ ! -d "$SRC/.git" ]; then
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$SRC"
    else
        git -C "$SRC" fetch --depth 1 origin && git -C "$SRC" reset --hard origin/master
    fi

    echo "[3/5] cmake configure (CUDA, sm_72)"
    cd "$SRC"
    rm -rf build
    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES=72 \
        -DLLAMA_CURL=ON \
        -DCMAKE_BUILD_TYPE=Release

    echo "[4/5] build (-j$(nproc))"
    cmake --build build --config Release -j"$(nproc)" \
        --target llama-server llama-cli llama-bench

    echo "[5/5] symlinking into $BIN_DIR"
    for bin in llama-server llama-cli llama-bench; do
        src="$SRC/build/bin/$bin"
        [ -x "$src" ] || { echo "missing $src" >&2; exit 1; }
        ln -sf "$src" "$BIN_DIR/$bin"
    done

    cd "$REPO_DIR"
    echo "Built llama-server:"
    "$BIN_DIR/llama-server" --version 2>&1 | head -n 3 || true
}

install_llama_swap
echo
install_llama_server

echo
echo "Done. Next: ./start.sh"
