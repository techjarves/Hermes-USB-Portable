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

CACHE_DIR="$PORTABLE_ROOT/.cache"
SRC_DIR="$PORTABLE_ROOT/src"

# ---------------------------------------------------------------------------
# Detect platform
# ---------------------------------------------------------------------------
OS_RAW="$(uname -s)"
ARCH_RAW="$(uname -m)"

case "$OS_RAW" in
    Linux*)     PLATFORM="linux" ;;
    Darwin*)    PLATFORM="macos" ;;
    *)
        echo "[ERROR] Unsupported OS: $OS_RAW"
        exit 1
        ;;
esac

case "$ARCH_RAW" in
    x86_64|amd64) ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        echo "[ERROR] Unsupported architecture: $ARCH_RAW"
        exit 1
        ;;
esac

RUNTIME_DIR="$CACHE_DIR/runtimes/${PLATFORM}-${ARCH}"
BIN_DIR="$RUNTIME_DIR/bin"
TMP_DIR="$RUNTIME_DIR/_tmp"

mkdir -p "$RUNTIME_DIR" "$SRC_DIR" "$BIN_DIR" "$TMP_DIR"

# ---------------------------------------------------------------------------
# Health check: if ready.flag exists but core files are missing, start fresh
# ---------------------------------------------------------------------------
if [ -f "$RUNTIME_DIR/ready.flag" ]; then
    if [ ! -x "$RUNTIME_DIR/python/bin/python3" ] || [ ! -x "$RUNTIME_DIR/uv/uv" ]; then
        echo "[WARN]  ready.flag exists but core files are missing — restarting setup ..."
        rm -f "$RUNTIME_DIR/ready.flag"
    fi
fi

# ---------------------------------------------------------------------------
# URL builders based on platform+arch
# ---------------------------------------------------------------------------
# python-build-standalone uses "aarch64" while macOS uname -m reports "arm64"
case "$ARCH_RAW" in
    arm64) PYTHON_ARCH="aarch64" ;;
    *)     PYTHON_ARCH="$ARCH_RAW" ;;
esac

# Pinned runtime versions. Python 3.14 since portable-v1.9.0: hermes-agent v0.22.x
# marks its core deps (openai, ruamel, certifi, truststore ...) python_version >= '3.14',
# so on 3.13 a chat dies with "No module named 'ruamel'". Same build the official
# installer ships (python-build-standalone 20261021).
PY_TAG="20261021"; PY_VER="3.14.9"
NODE_VER="24.16.0"; UV_VER="0.11.21"; RG_VER="15.1.0"
if [ "$PLATFORM" = "macos" ]; then
    PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/cpython-${PY_VER}+${PY_TAG}-${PYTHON_ARCH}-apple-darwin-install_only.tar.gz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-darwin-${ARCH}.tar.gz"
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${PYTHON_ARCH}-apple-darwin.tar.gz"
    RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-${PYTHON_ARCH}-apple-darwin.tar.gz"
else
    PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/cpython-${PY_VER}+${PY_TAG}-${ARCH_RAW}-unknown-linux-gnu-install_only.tar.gz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-${ARCH}.tar.xz"
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${ARCH_RAW}-unknown-linux-gnu.tar.gz"
    RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-${ARCH_RAW}-unknown-linux-musl.tar.gz"
fi

# Hermes Agent source is PINNED to the release recorded in VERSION
# (`hermes_agent_ref:`). The cached archive name carries the ref, so bumping the
# pin downloads fresh source instead of silently reusing an old tarball (before
# v1.9.0 setup took main HEAD once and then reused source.tar.gz forever).
HERMES_AGENT_REF="$(awk '/^hermes_agent_ref:/{print $2; exit}' "$PORTABLE_ROOT/VERSION" 2>/dev/null || true)"
HERMES_AGENT_REF="${HERMES_AGENT_REF:-main}"
if [ "$HERMES_AGENT_REF" = "main" ]; then
    SOURCE_URL="https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz"
else
    SOURCE_URL="https://github.com/NousResearch/hermes-agent/archive/refs/tags/${HERMES_AGENT_REF}.tar.gz"
fi
# Which Python packages get installed (locked set, extras, Playwright pin) is
# decided in scripts/install-deps.sh, shared with launch.sh.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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
                echo "        $name already cached ($(( size / 1024 / 1024 )) MB)."
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
    echo "        Download complete ($(( dsize / 1024 / 1024 )) MB)."
}

# ---------------------------------------------------------------------------
# Filesystem capability — exFAT/NTFS (the usual cross-platform USB formats)
# cannot store POSIX symlinks on Linux: `ln -s` fails with EPERM, and so does
# `tar -x` on any archive that contains symlinks (portable Python/Node both do).
# That is the root cause of first-run setup failing on Linux. We detect it once
# and, when symlinks are unsupported, extract on the host's local disk (where
# symlinks work) and copy the result back with symlinks DEREFERENCED into real
# files — which exFAT can store. macOS/native filesystems keep the fast path.
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "macos" ]; then
    LOCAL_BASE="${TMPDIR:-/tmp}"
else
    LOCAL_BASE="/tmp"
fi
# Keep this formula byte-identical to launch.sh's venv-rebuild path so the venv
# directory name matches across setup and any later rebuild (note: `echo` adds a
# trailing newline that is part of the hashed input — intentional, do not change).
DRIVE_ID="$(echo "$RUNTIME_DIR" | md5sum 2>/dev/null | cut -c1-8 || echo "hermes")"
STAGE_BASE="$LOCAL_BASE/hermes-portable-stage-$DRIVE_ID"

supports_symlinks() {
    local probe="$1/.hermes-symtest.$$"
    if ln -s ok "$probe" 2>/dev/null; then
        rm -f "$probe" 2>/dev/null || true
        return 0
    fi
    return 1
}

if supports_symlinks "$RUNTIME_DIR"; then
    DRIVE_SYMLINKS=1
else
    DRIVE_SYMLINKS=0
    warn "Drive filesystem can't store symlinks (exFAT/NTFS)."
    warn "Runtime files will be materialised as real files; venv goes on local disk."
fi

# Extract $1 into $2. $3 = tar compression flag ("z" for .tar.gz, "" lets GNU
# tar auto-detect, e.g. .tar.xz). On no-symlink drives, stage on local disk and
# deref-copy onto the drive so symlinked entries become real files.
_extract_archive() {
    local archive="$1" dest="$2" zflag="$3"
    echo "        Extracting $(basename "$archive") ..."
    rm -rf "$dest"

    if [ "${DRIVE_SYMLINKS:-1}" -eq 1 ]; then
        mkdir -p "$dest"
        if ! tar -x${zflag}f "$archive" -C "$dest" --strip-components=1; then
            rm -rf "$dest"; rm -f "$archive"
            echo "        ERROR: tar extraction failed for $(basename "$archive") (corrupted archive deleted)"
            return 1
        fi
        return 0
    fi

    # No-symlink drive: extract on local disk, then deref-copy onto the drive.
    local stage="$STAGE_BASE/$(basename "$dest")"
    rm -rf "$stage"; mkdir -p "$stage"
    if ! tar -x${zflag}f "$archive" -C "$stage" --strip-components=1; then
        rm -rf "$stage" "$dest"; rm -f "$archive"
        echo "        ERROR: tar extraction failed for $(basename "$archive") (corrupted archive deleted)"
        return 1
    fi
    mkdir -p "$dest"
    # -R recursive, -L dereference symlinks -> real files (exFAT-safe).
    cp -RL "$stage/." "$dest/" 2>/dev/null || cp -RLf "$stage/." "$dest/" 2>/dev/null || true
    rm -rf "$stage"
}

extract_tgz() { _extract_archive "$1" "$2" "z"; }
extract_txz() { _extract_archive "$1" "$2" ""; }

# ---------------------------------------------------------------------------
# 1. Portable Python
# ---------------------------------------------------------------------------
step "Installing portable Python ${PY_VER} ..."
# The archive name carries the version, so a version bump never reuses an old
# cached python.tar.gz (the same trap the hermes-agent source fell into).
PY_ARCHIVE="$RUNTIME_DIR/python-${PY_VER}.tar.gz"
if ! download "$PYTHON_URL" "$PY_ARCHIVE"; then
    echo "[ERROR] Failed to download Python. Check your internet connection."
    exit 1
fi
for _old in "$RUNTIME_DIR"/python.tar.gz "$RUNTIME_DIR"/python-*.tar.gz; do
    { [ -f "$_old" ] && [ "$_old" != "$PY_ARCHIVE" ] && rm -f "$_old"; } || true
done
# Skip re-extraction only when the unpacked interpreter is the pinned version.
_PY_HAVE="$("$RUNTIME_DIR/python/bin/python3" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)"
if [ "$_PY_HAVE" != "$PY_VER" ]; then
    [ -n "$_PY_HAVE" ] && echo "        Replacing Python $_PY_HAVE with $PY_VER ..."
    extract_tgz "$PY_ARCHIVE" "$RUNTIME_DIR/python"
else
    echo "        Python $PY_VER already extracted — skipping."
fi
done_msg "Python ready"

# ---------------------------------------------------------------------------
# 2. Node.js
# ---------------------------------------------------------------------------
step "Installing Node.js ${NODE_VER} (LTS) ..."
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
            extract_tgz "$NODE_ARCHIVE" "$RUNTIME_DIR/node" || {
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
# uv ships `uv` + `uvx` (uvx is a hardlink/symlink to uv) — extract_tgz
# dereferences them into real files so the exFAT drive can hold them.
if extract_tgz "$UV_ARCHIVE" "$RUNTIME_DIR/uv"; then
    chmod +x "$RUNTIME_DIR/uv/uv" "$RUNTIME_DIR/uv/uvx" 2>/dev/null || true
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
    # Stage on local disk: the rg tarball has a man-page symlink that would
    # abort `tar` (under set -e) on exFAT. We only need the rg binary anyway.
    RG_STAGE="$STAGE_BASE/rg"
    rm -rf "$RG_STAGE"; mkdir -p "$RG_STAGE"
    if tar -xzf "$RG_ARCHIVE" -C "$RG_STAGE" --strip-components=1 2>/dev/null \
       || tar -xzf "$RG_ARCHIVE" -C "$RG_STAGE" 2>/dev/null; then
        RG_BIN="$(find "$RG_STAGE" -name rg -type f 2>/dev/null | head -1)"
        if [ -n "$RG_BIN" ] && [ -f "$RG_BIN" ]; then
            cp "$RG_BIN" "$BIN_DIR/rg"
            chmod +x "$BIN_DIR/rg"
            done_msg "ripgrep ready"
        else
            warn "ripgrep binary not found in archive"
        fi
    else
        warn "ripgrep extraction failed — Hermes will use grep fallback"
    fi
    rm -rf "$RG_STAGE"
else
    warn "ripgrep not available for ${PLATFORM}-${ARCH} — Hermes will use grep fallback"
fi

# ---------------------------------------------------------------------------
# 5. Hermes source code
# ---------------------------------------------------------------------------
step "Downloading Hermes Agent source code (${HERMES_AGENT_REF}) ..."
SRC_ARCHIVE="$RUNTIME_DIR/source-${HERMES_AGENT_REF}.tar.gz"
if ! download "$SOURCE_URL" "$SRC_ARCHIVE"; then
    echo "[ERROR] Failed to download Hermes source. Aborting."
    exit 1
fi
# extract_tgz handles the exFAT no-symlink case (stage locally, deref-copy);
# on native filesystems it extracts straight to the destination. Skip it when
# the drive already holds this release: re-running setup (venv repair, Python
# bump) must not rewrite ~1.4 GB of source onto a slow stick.
if [ "$(cat "$SRC_DIR/hermes-agent/.portable-ref" 2>/dev/null || true)" = "$HERMES_AGENT_REF" ] \
   && [ "$HERMES_AGENT_REF" != "main" ] && [ -f "$SRC_DIR/hermes-agent/pyproject.toml" ]; then
    echo "        Hermes Agent $HERMES_AGENT_REF already extracted — skipping."
elif ! extract_tgz "$SRC_ARCHIVE" "$SRC_DIR/hermes-agent"; then
    echo "[ERROR] Failed to extract Hermes source. Aborting."
    exit 1
fi
# Record which release is on the drive (read by launch.sh / launch.bat). No
# trailing newline, so every platform compares the same bytes.
printf '%s' "$HERMES_AGENT_REF" > "$SRC_DIR/hermes-agent/.portable-ref"
# Drop source archives of older pins (they are 50-70 MB each on the stick).
for _old in "$RUNTIME_DIR"/source.tar.gz "$RUNTIME_DIR"/source-*.tar.gz; do
    { [ -f "$_old" ] && [ "$_old" != "$SRC_ARCHIVE" ] && rm -f "$_old"; } || true
done
done_msg "Source code ready (${HERMES_AGENT_REF})"

# ---------------------------------------------------------------------------
# 6. macOS gatekeeper / permissions cleanup
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "macos" ]; then
    step "Removing macOS quarantine attributes ..."
    xattr -dr com.apple.quarantine "$RUNTIME_DIR/python" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$RUNTIME_DIR/node" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$RUNTIME_DIR/uv" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$BIN_DIR" 2>/dev/null || true
    # exFAT keeps extended attributes in binary AppleDouble "._<name>" twins -
    # extraction leaves ~23,000 of them in the source tree, and loaders that
    # glob *.py read them as source (v0.22.5 tool discovery crashed on
    # tools/._*.py). dot_clean -m deletes them.
    dot_clean -m "$SRC_DIR/hermes-agent" 2>/dev/null || true
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
PYTHON_EXE="$RUNTIME_DIR/python/bin/python3"
UV_EXE="$RUNTIME_DIR/uv/uv"

if [ ! -x "$PYTHON_EXE" ]; then
    echo "[ERROR] Python executable not found at $PYTHON_EXE"
    exit 1
fi

# A venv is built out of symlinks to the base interpreter, so on a no-symlink
# drive (exFAT/NTFS) it MUST live on the host's local disk. We record the chosen
# location in venv.path; launch.sh reads that pointer (and rebuilds the venv on
# local disk if a reboot purged it). On native filesystems the venv stays on
# the drive for full portability.
if [ "${DRIVE_SYMLINKS:-1}" -eq 1 ]; then
    VENV_DIR="$RUNTIME_DIR/venv"
else
    VENV_DIR="$LOCAL_BASE/hermes-portable-venv-$DRIVE_ID"
    export UV_CACHE_DIR="$LOCAL_BASE/hermes-uv-cache-$DRIVE_ID"
    mkdir -p "$UV_CACHE_DIR"
    echo "        exFAT drive — building venv on local disk: $VENV_DIR"
fi
echo "$VENV_DIR" > "$RUNTIME_DIR/venv.path"
rm -rf "$VENV_DIR"

# --seed gives us pip/setuptools inside the venv; fall back without it if the
# seed step is unavailable. (Bare $? checks don't work under set -e.)
if ! "$UV_EXE" venv "$VENV_DIR" --python "$PYTHON_EXE" --seed 2>/dev/null; then
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

# scripts/install-deps.sh is shared with launch.sh (venv rebuilds): it installs
# the exact package set upstream locks in uv.lock (a fresh resolve hits
# upstream's Pillow override and fails), then hermes-agent itself (editable,
# compat mode), then Playwright, verifies `import hermes_cli.main`, and stamps
# the venv with src/hermes-agent/.portable-ref. UV_CACHE_DIR set above is kept.
if ! bash "$PORTABLE_ROOT/scripts/install-deps.sh" "$PORTABLE_ROOT" "$VENV_DIR"; then
    echo "[ERROR] Failed to install Hermes dependencies"
    exit 1
fi
done_msg "Dependencies installed"

# ---------------------------------------------------------------------------
# 9. Install messaging dependencies (Telegram, etc.)
# ---------------------------------------------------------------------------
# Hermes [all] intentionally excludes messaging deps for size.
# The lazy-install system is supposed to auto-install on first use,
# but it can fail silently in some environments. Pre-install here
# so Telegram works out of the box.
# ---------------------------------------------------------------------------
step "Installing messaging dependencies (Telegram) ..."
if ! "$UV_EXE" pip install --python "$VENV_PYTHON" --link-mode=copy "python-telegram-bot[webhooks]==22.8" 2>/dev/null; then
    if ! "$VENV_PYTHON" -m pip install "python-telegram-bot[webhooks]==22.8" 2>/dev/null; then
        warn "python-telegram-bot install failed - will retry on first use"
    else
        done_msg "python-telegram-bot ready"
    fi
else
    done_msg "python-telegram-bot ready"
fi

# ---------------------------------------------------------------------------
# 10. Install Playwright browsers (optional)
# ---------------------------------------------------------------------------
step "Installing Playwright browsers (optional) ..."
export PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/playwright"
if "$VENV_PYTHON" -m playwright install chromium 2>/dev/null; then
    done_msg "Playwright browsers ready"
else
    warn "Playwright browser install failed (web tools may be limited)"
fi

# ---------------------------------------------------------------------------
# 11. Mark ready
# ---------------------------------------------------------------------------
touch "$RUNTIME_DIR/ready.flag"
rm -rf "$TMP_DIR" "$STAGE_BASE" 2>/dev/null || true

echo ""
echo "========================================"
echo "   Setup Complete! Launching Hermes..."
echo "========================================"
sleep 1
