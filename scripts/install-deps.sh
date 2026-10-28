#!/bin/bash
# ============================================================================
# Hermes Portable - install Hermes Agent's Python packages into a venv
# ============================================================================
# Usage: install-deps.sh <portable-root> <venv-dir>
#
# Called by scripts/setup-unix.sh (first run / pin change) and by launch.sh
# (venv rebuilt after a reboot, or venv older than the source on the drive).
#
# Installs EXACTLY the dependency set upstream locks in uv.lock, then
# hermes-agent itself (editable, compat mode), then Playwright. Exit 0 only
# when `import hermes_cli.main` works in the venv; on success the venv is
# stamped with src/hermes-agent/.portable-ref.
# ============================================================================
set -u

ROOT="${1:?usage: install-deps.sh <portable-root> <venv-dir>}"
VENV="${2:?usage: install-deps.sh <portable-root> <venv-dir>}"
SRC="$ROOT/src/hermes-agent"

case "$(uname -s)" in
    Darwin*) PLATFORM="macos" ;;
    Linux*)  PLATFORM="linux" ;;
    *) echo "[ERROR] Unsupported OS: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "[ERROR] Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
RT="$ROOT/.cache/runtimes/${PLATFORM}-${ARCH}"
UV="$RT/uv/uv"
PY="$VENV/bin/python"

# Optional-dependency groups from hermes-agent's pyproject.toml.
EXTRAS="all anthropic telegram"
# Pinned to the chromium build already cached on the drive (playwright/), so an
# update never rewrites ~500 MB of browser files onto a slow USB stick.
PLAYWRIGHT_PIN="playwright==1.64.1"

if [ "$PLATFORM" = "macos" ]; then LOCAL_BASE="${TMPDIR:-/tmp}"; else LOCAL_BASE="/tmp"; fi
LOCAL_BASE="${LOCAL_BASE%/}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$LOCAL_BASE/hermes-uv-cache}"
REQ="$LOCAL_BASE/hermes-portable-requirements.txt"
rm -f "$REQ"

EXTRA_ARGS=()
for e in $EXTRAS; do EXTRA_ARGS+=(--extra "$e"); done
EXTRAS_CSV="$(echo $EXTRAS | tr ' ' ',')"

[ -x "$PY" ] || { echo "[ERROR] No Python in venv: $VENV"; exit 1; }
[ -f "$SRC/pyproject.toml" ] || { echo "[ERROR] Hermes source missing: $SRC"; exit 1; }

ok=0
# 1) Locked install - the normal path. uv.lock carries upstream's resolution,
#    including its [tool.uv] override-dependencies (e.g. Pillow 13.0.0 over
#    browser-harness's exact pillow==12.3.0 pin). A fresh resolve cannot
#    reproduce those overrides: pip and `uv pip install -e .[extras]` both
#    stop with "ResolutionImpossible". So export the lock and install it as-is.
if [ -x "$UV" ] && [ -f "$SRC/uv.lock" ] \
   && "$UV" export --frozen --no-hashes --no-emit-project --no-dev "${EXTRA_ARGS[@]}" \
          --project "$SRC" -o "$REQ" >/dev/null 2>&1; then
    echo "        Installing the locked package set ($(grep -c '==' "$REQ") packages from uv.lock) ..."
    if "$UV" pip install --python "$PY" --link-mode=copy --no-deps -r "$REQ" \
       && "$UV" pip install --python "$PY" --link-mode=copy --no-deps -C editable_mode=compat -e "$SRC"; then
        ok=1
    fi
fi

# 2) No usable lock (e.g. a `main` pin or an old tag): let uv resolve.
#    editable_mode=compat: hermes-agent >= 0.22 builds its root modules in
#    setup.py, and setuptools' default editable finder then maps no packages
#    ("No module named 'hermes_cli'"); compat puts the source tree on sys.path.
if [ "$ok" -ne 1 ] && [ -x "$UV" ]; then
    echo "        Locked install unavailable - resolving with uv ..."
    "$UV" pip install --python "$PY" --link-mode=copy -C editable_mode=compat -e "$SRC[$EXTRAS_CSV]" && ok=1
fi

# 3) Last resort: pip.
if [ "$ok" -ne 1 ]; then
    echo "        uv install failed - falling back to pip ..."
    "$PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
    if [ -s "$REQ" ]; then
        "$PY" -m pip install --no-deps -r "$REQ" \
        && "$PY" -m pip install --no-deps --config-settings editable_mode=compat -e "$SRC" && ok=1
    else
        "$PY" -m pip install --config-settings editable_mode=compat -e "$SRC[$EXTRAS_CSV]" && ok=1
    fi
fi
rm -f "$REQ"
[ "$ok" -eq 1 ] || { echo "[ERROR] Installing Hermes' Python packages failed."; exit 1; }

# Playwright (browser tools) is optional: keep its own deps, never fail on it.
"$UV" pip install --python "$PY" --link-mode=copy "$PLAYWRIGHT_PIN" >/dev/null 2>&1 \
    || "$PY" -m pip install "$PLAYWRIGHT_PIN" >/dev/null 2>&1 \
    || echo "[WARN]  Playwright install failed (browser tools will be limited)."

if ! "$PY" -c "import hermes_cli.main" >/dev/null 2>&1; then
    echo "[ERROR] Packages installed, but 'import hermes_cli.main' fails in $VENV."
    exit 1
fi

# Install stamp: a release tarball has no .git, so without it `hermes --version`
# says "vunknown" and `hermes update` assumes a git checkout. The stamp records
# the pinned release (from VERSION) and marks the tree as externally updated
# (this launcher updates it). Written only when VERSION and the tree agree.
H_VER="$(awk '/^hermes_agent_version:/{print $2; exit}' "$ROOT/VERSION" 2>/dev/null || true)"
H_COMMIT="$(awk '/^hermes_agent_commit:/{print $2; exit}' "$ROOT/VERSION" 2>/dev/null || true)"
H_REF="$(cat "$SRC/.portable-ref" 2>/dev/null || true)"
if [ -n "$H_VER" ] && [ -n "$H_COMMIT" ] && [ "$H_REF" = "v$H_VER" ] && [ -f "$SRC/scripts/write_install_stamp.py" ]; then
    ( cd "$SRC" && "$PY" scripts/write_install_stamp.py --output install-stamp.json \
          --update-mechanism external --commit "$H_COMMIT" --branch "$H_REF" \
          --base-version "$H_VER" --display-version "$H_VER" --distance 0 --source build ) >/dev/null 2>&1 \
        || echo "[WARN]  Could not write install-stamp.json (hermes --version will say unknown)."
fi
cat "$SRC/.portable-ref" > "$VENV/.portable-ref" 2>/dev/null || true
echo "[OK]    Hermes packages installed ($(cat "$SRC/.portable-ref" 2>/dev/null || echo unpinned source))."
exit 0
