#!/bin/bash
# ============================================================================
# Hermes Portable - Runtime Location Resolver (sourced by launch.sh & setup-unix.sh)
# ============================================================================
# Why this exists:
#   Cross-platform USB drives are usually formatted exFAT/NTFS/FAT, which do not
#   support POSIX symlinks. On Linux/macOS the python-build-standalone runtime,
#   the venv, and node_modules all rely on symlinks, so installing them directly
#   on such a drive fails with "Cannot create symlink: Operation not permitted".
#
# Resolution:
#   If the drive supports symlinks (ext4/xfs/APFS, etc.) -> keep the runtime on
#   the drive (fully portable). If it does not (exFAT, etc.) -> place the runtime
#   on local disk under ~/.cache/hermes-portable/<id>/ while data/ and src/ stay
#   on the drive. A Linux/macOS runtime cannot be shared with other OSes anyway,
#   so storing it locally costs nothing in portability.
#
# Inputs (must be set before sourcing): PORTABLE_ROOT, CACHE_DIR, PLATFORM, ARCH
# Outputs: RUNTIME_DIR, RUNTIME_RELOCATED (0/1)
# Optional override: HERMES_RUNTIME_DIR (force a specific runtime root)
# ============================================================================

_hermes_hash() {
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$1" | md5sum | cut -c1-8
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 | cut -c1-8
    else
        printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-8
    fi
}

_hermes_supports_symlinks() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null || return 1
    local probe="$dir/.hermes_symtest.$$"
    rm -f "$probe" 2>/dev/null
    if ln -s target "$probe" 2>/dev/null; then
        rm -f "$probe" 2>/dev/null
        return 0
    fi
    rm -f "$probe" 2>/dev/null
    return 1
}

if [ -n "$HERMES_RUNTIME_DIR" ]; then
    # User-forced location
    RUNTIME_DIR="$HERMES_RUNTIME_DIR/runtimes/${PLATFORM}-${ARCH}"
    RUNTIME_RELOCATED=1
elif _hermes_supports_symlinks "$CACHE_DIR"; then
    # Drive supports symlinks -> keep runtime on the portable drive
    RUNTIME_DIR="$CACHE_DIR/runtimes/${PLATFORM}-${ARCH}"
    RUNTIME_RELOCATED=0
else
    # Drive cannot hold symlinks (exFAT/NTFS/FAT) -> relocate runtime to local disk
    _hermes_id="$(_hermes_hash "$PORTABLE_ROOT")"
    _hermes_base="${HERMES_LOCAL_HOME:-$HOME}/.cache/hermes-portable/$_hermes_id"
    RUNTIME_DIR="$_hermes_base/runtimes/${PLATFORM}-${ARCH}"
    RUNTIME_RELOCATED=1
fi

export RUNTIME_DIR RUNTIME_RELOCATED
