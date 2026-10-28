#!/bin/bash
# ============================================================================
# Setup Hermes Agent inside Ubuntu Live Boot Session
# ============================================================================
set -e

PORTABLE_ROOT="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="${HOME:-/home/ubuntu}"

echo "================================================================"
echo "    Setting up Hermes Portable inside Ubuntu Live Session"
echo "================================================================"
echo "USB Drive located at: $PORTABLE_ROOT"

# 1. Desktop shortcut
if [ -d "$USER_HOME/Desktop" ]; then
    echo "[1/3] Installing Desktop shortcut..."
    cat > "$USER_HOME/Desktop/Hermes.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Hermes Agent Portable
Comment=Launch Hermes Portable from USB
Exec=bash -c "cd '$PORTABLE_ROOT' && ./launch.sh"
Icon=utilities-terminal
Terminal=true
Categories=Development;Utility;System;
EOF
    chmod +x "$USER_HOME/Desktop/Hermes.desktop"
    if command -v gio >/dev/null 2>&1; then
        gio set "$USER_HOME/Desktop/Hermes.desktop" metadata::trusted true 2>/dev/null || true
    fi
    echo "      Desktop shortcut ready: $USER_HOME/Desktop/Hermes.desktop"
fi

# 2. Command line alias / symlink in /usr/local/bin
echo "[2/3] Registering global 'hermes-usb' command..."
if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
    sudo tee /usr/local/bin/hermes-usb > /dev/null <<EOF
#!/bin/bash
cd "$PORTABLE_ROOT" && exec ./launch.sh "\$@"
EOF
    sudo chmod +x /usr/local/bin/hermes-usb 2>/dev/null || true
    echo "      Command registered! You can now run 'hermes-usb' from any terminal."
else
    mkdir -p "$USER_HOME/.local/bin"
    cat > "$USER_HOME/.local/bin/hermes-usb" <<EOF
#!/bin/bash
cd "$PORTABLE_ROOT" && exec ./launch.sh "\$@"
EOF
    chmod +x "$USER_HOME/.local/bin/hermes-usb"
    echo "      Command registered at $USER_HOME/.local/bin/hermes-usb"
fi

# 3. Launch Hermes now
echo "[3/3] Launching Hermes Portable..."
echo "================================================================"
cd "$PORTABLE_ROOT"
exec ./launch.sh
