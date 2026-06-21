#!/bin/bash
# ============================================================================
# Hermes Portable - Unix Runtime Setup (macOS / Linux)
# ============================================================================
# Downloads and installs portable Python, Node.js, uv, ripgrep,
# clones Hermes source, creates venv, and installs dependencies.
# ============================================================================

set -e

PORTABLE_ROOT="$1"
if [ -z "$PORTABLE_ROOT" ]; then
  echo "Usage: $0 <portable-root>"
  exit 1
fi

# Clean up macOS metadata junk files (._*) from exFAT drives to prevent pip/uv errors
find "$PORTABLE_ROOT" -name "._*" -depth -exec rm -f {} \; 2>/dev/null || true


CACHE_DIR="$PORTABLE_ROOT/.cache"
SRC_DIR="$PORTABLE_ROOT/src"

step() {
  echo ""
  echo "[SETUP] $1"
}

done_msg() {
  echo "[OK]    $1"
}

warn() {
  echo "[WARN]  $1"
}

portable_id() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-8
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 | cut -c1-8
  else
    basename "$1" | tr -cd '[:alnum:]' | cut -c1-8
  fi
}

# ---------------------------------------------------------------------------
# Detect platform
# ---------------------------------------------------------------------------
OS_RAW="$(uname -s)"
ARCH_RAW="$(uname -m)"

case "$OS_RAW" in
Linux*) PLATFORM="linux" ;;
Darwin*) PLATFORM="macos" ;;
*)
  echo "[ERROR] Unsupported OS: $OS_RAW"
  exit 1
  ;;
esac

case "$ARCH_RAW" in
x86_64 | amd64) ARCH="x64" ;;
aarch64 | arm64) ARCH="arm64" ;;
*)
  echo "[ERROR] Unsupported architecture: $ARCH_RAW"
  exit 1
  ;;
esac

RUNTIME_DIR="$CACHE_DIR/runtimes/${PLATFORM}-${ARCH}"
BIN_DIR="$RUNTIME_DIR/bin"
TMP_DIR="$RUNTIME_DIR/_tmp"
VENV_PATH_FILE="$RUNTIME_DIR/venv.path"

mkdir -p "$RUNTIME_DIR" "$SRC_DIR" "$BIN_DIR" "$TMP_DIR"

# ---------------------------------------------------------------------------
# Health check: if ready.flag exists but core files are missing, start fresh
# ---------------------------------------------------------------------------
if [ -f "$RUNTIME_DIR/ready.flag" ]; then
  if [ -f "$VENV_PATH_FILE" ]; then
    HEALTH_VENV_DIR="$(cat "$VENV_PATH_FILE")"
  else
    HEALTH_VENV_DIR="$RUNTIME_DIR/venv"
  fi
  if [ ! -x "$RUNTIME_DIR/python/bin/python3" ] || [ ! -x "$RUNTIME_DIR/uv/uv" ] || [ ! -x "$HEALTH_VENV_DIR/bin/python" ]; then
    warn "ready.flag exists but core files are missing — restarting setup ..."
    rm -f "$RUNTIME_DIR/ready.flag"
  fi
fi

# ---------------------------------------------------------------------------
# URL builders based on platform+arch
# ---------------------------------------------------------------------------
# python-build-standalone uses "aarch64" while macOS uname -m reports "arm64"
case "$ARCH_RAW" in
arm64) PYTHON_ARCH="aarch64" ;;
*) PYTHON_ARCH="$ARCH_RAW" ;;
esac

if [ "$PLATFORM" = "macos" ]; then
  PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260510/cpython-3.11.15+20260510-${PYTHON_ARCH}-apple-darwin-install_only.tar.gz"
  NODE_URL="https://nodejs.org/dist/v22.14.0/node-v22.14.0-darwin-${ARCH}.tar.gz"
  UV_URL="https://github.com/astral-sh/uv/releases/download/0.7.8/uv-${PYTHON_ARCH}-apple-darwin.tar.gz"
  RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${PYTHON_ARCH}-apple-darwin.tar.gz"
else
  PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260510/cpython-3.11.15+20260510-${ARCH_RAW}-unknown-linux-gnu-install_only.tar.gz"
  NODE_URL="https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-${ARCH}.tar.xz"
  UV_URL="https://github.com/astral-sh/uv/releases/download/0.7.8/uv-${ARCH_RAW}-unknown-linux-gnu.tar.gz"
  RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${ARCH_RAW}-unknown-linux-musl.tar.gz"
fi

SOURCE_URL="https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz"

download() {
  local url="$1"
  local out="$2"
  local name
  name="$(basename "$url")"

  if [ -f "$out" ]; then
    local size
    size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
    if [ "$size" -gt 0 ]; then
      # Verify archive integrity to handle interrupted downloads
      local corrupt=0
      if [[ "$name" == *.tar.gz ]]; then
        gzip -t "$out" 2>/dev/null || corrupt=1
      elif [[ "$name" == *.tar.xz ]]; then
        xz -t "$out" 2>/dev/null || corrupt=1
      fi

      if [ "$corrupt" -eq 1 ]; then
        warn "$name is corrupted or incomplete — deleting and re-downloading ..."
        rm -f "$out"
      else
        echo "        $name already cached ($((size / 1024 / 1024)) MB)."
        return 0
      fi
    else
      warn "$name exists but is 0 bytes — re-downloading ..."
      rm -f "$out"
    fi
  fi

  echo "        Downloading $name ..."
  echo "        URL: $url"
  if ! curl -fL --progress-bar --retry 3 --connect-timeout 30 --max-time 600 "$url" -o "$out"; then
    rm -f "$out"
    echo "        FAILED to download $name"
    return 1
  fi

  # Validate downloaded file
  if [ ! -f "$out" ]; then
    echo "        Download succeeded but file not found: $out"
    return 1
  fi
  local dsize
  dsize="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
  if [ "$dsize" -eq 0 ]; then
    rm -f "$out"
    echo "        Downloaded file is 0 bytes: $name"
    return 1
  fi
  echo "        Download complete ($((dsize / 1024 / 1024)) MB)."
}

extract_txz() {
  local archive="$1"
  local dest="$2"
  local tmp_dir="/tmp/${dest}_tmp"
  echo "        Extracting $(basename "$archive") ..."
  # Clean up partial extraction from previous failed run
  if [ -d "$dest" ]; then
    rm -rf "$dest"
  fi
  if [ -d "$tmp_dir" ]; then
    echo "deleting tmp_dir"
    rm -rf "$tmp_dir"
  fi
  mkdir -p "$dest"
  mkdir -p "$tmp_dir"
  if ! tar -xf "$archive" -C "$tmp_dir" --strip-components=1; then
    rm -rf "$tmp_dir"
    rm -f "$archive"
    echo "        ERROR: tar extraction failed for $(basename "$archive") (corrupted archive deleted)"
    return 1
  fi
  cp -R -L "$tmp_dir"/. "$dest"/ 2>/dev/null || true
  rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# 1. Portable Python
# ---------------------------------------------------------------------------
step "Installing portable Python 3.11 ..."
PY_ARCHIVE="$RUNTIME_DIR/python.tar.gz"
if ! download "$PYTHON_URL" "$PY_ARCHIVE"; then
  echo "[ERROR] Failed to download Python. Check your internet connection."
  exit 1
fi
# Bug fix: skip re-extraction if already unpacked (saves ~30s on repeat runs)
if [ ! -d "$RUNTIME_DIR/python/bin" ]; then
  extract_txz "$PY_ARCHIVE" "$RUNTIME_DIR/python"
else
  echo "        Already extracted — skipping."
fi
done_msg "Python ready"

# ---------------------------------------------------------------------------
# 2. Node.js
# ---------------------------------------------------------------------------
step "Installing Node.js 22 LTS ..."
NODE_ARCHIVE="$RUNTIME_DIR/node.tar.xz"
if [ "$PLATFORM" = "macos" ]; then
  NODE_ARCHIVE="$RUNTIME_DIR/node.tar.gz"
fi
if ! download "$NODE_URL" "$NODE_ARCHIVE"; then
  warn "Node.js download failed — web tools may be limited"
else
  # Bug fix: skip re-extraction if already unpacked
  if [ ! -d "$RUNTIME_DIR/node/bin" ]; then
    if [ "$PLATFORM" = "macos" ]; then
      extract_txz "$NODE_ARCHIVE" "$RUNTIME_DIR/node" || {
        warn "Node.js extraction failed — web tools may be limited"
      }
    else
      extract_txz "$NODE_ARCHIVE" "$RUNTIME_DIR/node" || {
        warn "Node.js extraction failed — web tools may be limited"
      }
    fi
  else
    echo "        Already extracted — skipping."
  fi
  [ -d "$RUNTIME_DIR/node/bin" ] && done_msg "Node.js ready"
fi

# ---------------------------------------------------------------------------
# 3. uv
# ---------------------------------------------------------------------------
step "Installing uv ..."
UV_ARCHIVE="$RUNTIME_DIR/uv.tar.gz"
if ! download "$UV_URL" "$UV_ARCHIVE"; then
  echo "[ERROR] Failed to download uv. Aborting."
  exit 1
fi
rm -rf "$RUNTIME_DIR/uv"
mkdir -p "$RUNTIME_DIR/uv"
if tar -xzf "$UV_ARCHIVE" -C "$RUNTIME_DIR/uv" --strip-components=1; then
  chmod +x "$RUNTIME_DIR/uv/uv" 2>/dev/null || true
  done_msg "uv ready"
else
  rm -rf "$RUNTIME_DIR/uv"
  echo "[ERROR] Failed to extract uv. Aborting."
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. ripgrep
# ---------------------------------------------------------------------------
step "Installing ripgrep ..."
RG_ARCHIVE="$RUNTIME_DIR/rg.tar.gz"
if download "$RG_URL" "$RG_ARCHIVE"; then
  mkdir -p "$TMP_DIR/rg"
  tar -xzf "$RG_ARCHIVE" -C "$TMP_DIR/rg" --strip-components=1
  if [ -f "$TMP_DIR/rg/rg" ]; then
    cp "$TMP_DIR/rg/rg" "$BIN_DIR/rg"
    chmod +x "$BIN_DIR/rg"
    done_msg "ripgrep ready"
  elif [ -f "$TMP_DIR/rg/ripgrep-14.1.1-*/rg" ]; then
    cp "$TMP_DIR/rg/ripgrep-"*/rg "$BIN_DIR/rg"
    chmod +x "$BIN_DIR/rg"
    done_msg "ripgrep ready"
  else
    warn "ripgrep binary not found in archive"
  fi
  rm -rf "$TMP_DIR/rg"
else
  warn "ripgrep not available for ${PLATFORM}-${ARCH} — Hermes will use grep fallback"
fi

# ---------------------------------------------------------------------------
# 5. Hermes source code
# ---------------------------------------------------------------------------
step "Downloading Hermes Agent source code ..."
SRC_ARCHIVE="$RUNTIME_DIR/source.tar.gz"
if ! download "$SOURCE_URL" "$SRC_ARCHIVE"; then
  echo "[ERROR] Failed to download Hermes source. Aborting."
  exit 1
fi
rm -rf "$TMP_DIR/source"
mkdir -p "$TMP_DIR/source"
tar -xzf "$SRC_ARCHIVE" -C "$TMP_DIR/source" --strip-components=1
rm -rf "$SRC_DIR/hermes-agent"
mv "$TMP_DIR/source" "$SRC_DIR/hermes-agent"
done_msg "Source code ready"

# ---------------------------------------------------------------------------
# 6. macOS gatekeeper / permissions cleanup
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "macos" ]; then
  step "Removing macOS quarantine attributes ..."
  xattr -dr com.apple.quarantine "$RUNTIME_DIR/python" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$RUNTIME_DIR/node" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$RUNTIME_DIR/uv" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$BIN_DIR" 2>/dev/null || true
  done_msg "Gatekeeper attributes cleared"
fi

# Make sure binaries are executable
chmod -R +x "$RUNTIME_DIR/python/bin" 2>/dev/null || true
chmod -R +x "$RUNTIME_DIR/node/bin" 2>/dev/null || true
chmod -R +x "$RUNTIME_DIR/uv" 2>/dev/null || true
chmod -R +x "$BIN_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Create virtual environment
# ---------------------------------------------------------------------------
step "Creating Python virtual environment ..."
PYTHON3_EXE="$RUNTIME_DIR/python/bin/python3"
PYTHON_EXE="$RUNTIME_DIR/python/bin/python"
UV_EXE="$RUNTIME_DIR/uv/uv"

if [ ! -x "$PYTHON_EXE" ]; then
  cp "$PYTHON3_EXE" "$PYTHON_EXE"
fi

if [ ! -x "$PYTHON_EXE" ]; then
  echo "[ERROR] Python executable not found at $PYTHON_EXE"
  exit 1
fi

if [ "$PLATFORM" = "macos" ]; then
  LOCAL_BASE="${TMPDIR:-/tmp}"
else
  LOCAL_BASE="/tmp"
fi

DRIVE_ID="$(portable_id "$RUNTIME_DIR")"
VENV_DIR="${LOCAL_BASE%/}/hermes-portable-venv-${DRIVE_ID}"
export UV_CACHE_DIR="${LOCAL_BASE%/}/hermes-uv-cache-${DRIVE_ID}"
mkdir -p "$UV_CACHE_DIR"
echo "$VENV_DIR" > "$VENV_PATH_FILE"

rm -rf "$VENV_DIR"
if ! "$UV_EXE" venv "$VENV_DIR" --python "$PYTHON_EXE" --seed 2>/dev/null; then
  rm -rf "$VENV_DIR"
  if ! "$UV_EXE" venv "$VENV_DIR" --python "$PYTHON_EXE"; then
    echo "[ERROR] Failed to create virtual environment"
    exit 1
  fi
fi
done_msg "Virtual environment ready"

# ---------------------------------------------------------------------------
# 8. Install Hermes dependencies
# ---------------------------------------------------------------------------
step "Installing Hermes Python dependencies ..."
echo "        This may take 3-10 minutes depending on your connection."
VENV_PYTHON="$VENV_DIR/bin/python"

# Try uv first (faster), fall back to pip on unsupported filesystem (e.g. ExFAT)
if ! "$UV_EXE" pip install --python "$VENV_PYTHON" --link-mode=copy -e "$SRC_DIR/hermes-agent[all]" 2>/dev/null; then
  echo "        uv install failed — falling back to pip ..."
  if ! "$VENV_PYTHON" -m ensurepip --upgrade >/dev/null 2>&1; then
    echo "[WARN] Could not install pip in virtual environment"
  fi
  if ! "$VENV_PYTHON" -m pip install -e "$SRC_DIR/hermes-agent[all]"; then
    echo "[ERROR] Failed to install Hermes dependencies"
    exit 1
  fi
fi
done_msg "Dependencies installed"

# ---------------------------------------------------------------------------
# 9. Install provider dependencies
# ---------------------------------------------------------------------------
step "Installing provider dependencies ..."
if ! "$UV_EXE" pip install --python "$VENV_PYTHON" --link-mode=copy "anthropic>=0.39.0" 2>/dev/null; then
  if ! "$VENV_PYTHON" -m pip install "anthropic>=0.39.0" 2>/dev/null; then
    warn "Anthropic provider install failed - install may retry on first use"
  else
    done_msg "Provider dependencies ready"
  fi
else
  done_msg "Provider dependencies ready"
fi

# ---------------------------------------------------------------------------
# 10. Install messaging dependencies (Telegram, etc.)
# ---------------------------------------------------------------------------
# Hermes [all] intentionally excludes messaging deps for size.
# The lazy-install system is supposed to auto-install on first use,
# but it can fail silently in some environments. Pre-install here
# so Telegram works out of the box.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Hermes [all] intentionally excludes messaging deps for size.
# The lazy-install system is supposed to auto-install on first use,
# but it can fail silently in some environments. Pre-install here
# so Telegram works out of the box.
# ---------------------------------------------------------------------------
step "Installing messaging dependencies (Telegram) ..."
if ! "$UV_EXE" pip install --python "$VENV_PYTHON" --link-mode=copy "python-telegram-bot[webhooks]==22.6" 2>/dev/null; then
  if ! "$VENV_PYTHON" -m pip install "python-telegram-bot[webhooks]==22.6" 2>/dev/null; then
    warn "python-telegram-bot install failed - will retry on first use"
  else
    done_msg "python-telegram-bot ready"
  fi
else
  done_msg "python-telegram-bot ready"
fi

# ---------------------------------------------------------------------------
# 11. Install Playwright browsers (optional)
# ---------------------------------------------------------------------------
step "Installing Playwright browsers (optional) ..."
export PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/playwright"
if "$VENV_PYTHON" -m playwright install chromium 2>/dev/null; then
  done_msg "Playwright browsers ready"
else
  warn "Playwright browser install failed (web tools may be limited)"
fi

# ---------------------------------------------------------------------------
# 12. Mark ready
# ---------------------------------------------------------------------------
touch "$RUNTIME_DIR/ready.flag"
rm -rf "$TMP_DIR"

echo ""
echo "========================================"
echo "   Setup Complete!"
echo "========================================"
sleep 1

echo ""
echo "========================================"
echo "   Local Offline LLM Setup"
echo "========================================"
echo "Would you like to set up a local model (llama.cpp) now?"
echo "This will open a web browser configuration tool to automatically scan your"
echo "hardware (VRAM, CPU) and download/configure the best model for your system."
read -p "Configure local LLM? (y/n) [n]: " choice
if [[ "$choice" =~ ^[yY] ]]; then
  echo "Launching local configuration server..."
  "$VENV_PYTHON" "$PORTABLE_ROOT/scripts/local_setup_server.py"
fi
