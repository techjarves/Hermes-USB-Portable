#!/bin/bash
# ============================================================================
# Hermes Portable Quick-Launch - Ubuntu & Hermes by Achu
# ============================================================================
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$DIR/setup-live-ubuntu.sh" ]; then
    echo "Configuring Hermes in Live environment..."
    bash "$DIR/setup-live-ubuntu.sh"
else
    cd "$DIR" && ./launch.sh "$@"
fi
