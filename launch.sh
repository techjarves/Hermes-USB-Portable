#!/bin/bash
# ============================================================================
# Hermes Agent - Portable Launcher (macOS / Linux)
# ============================================================================
# Terminal:   ./launch.sh
# macOS Finder: rename this file to "launch.command" for double-click support.
# On first run, it downloads ~600MB of runtime files automatically.
# All data stays in the "data/" folder — nothing touches the host computer.
# ============================================================================

set -e

# Resolve portable root (directory containing this script)
PORTABLE_ROOT="$(cd "$(dirname "$0")" && pwd)"
HERMES_HOME="$PORTABLE_ROOT/data"
CACHE_DIR="$PORTABLE_ROOT/.cache"
SRC_DIR="$PORTABLE_ROOT/src"

# ---------------------------------------------------------------------------
# Detect OS and architecture
# ---------------------------------------------------------------------------
OS_RAW="$(uname -s)"
ARCH_RAW="$(uname -m)"

case "$OS_RAW" in
    Linux*)     PLATFORM="linux" ;;
    Darwin*)    PLATFORM="macos" ;;
    CYGWIN*|MINGW*|MSYS*) PLATFORM="windows" ;;
    *)
        echo "[ERROR] Unsupported operating system: $OS_RAW"
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
# First-run setup
# ---------------------------------------------------------------------------
if [ ! -f "$RUNTIME_DIR/ready.flag" ]; then
    echo ""
    echo "============================================"
    echo "    Hermes Portable - First Run Setup"
    echo "============================================"
    echo "  Platform: ${PLATFORM}-${ARCH}"
    echo "  This will download ~600MB of runtime files."
    echo "  Please be patient."
    echo "============================================"
    echo ""
    bash "$PORTABLE_ROOT/scripts/setup-unix.sh" "$PORTABLE_ROOT"
    if [ $? -ne 0 ]; then
        echo ""
        echo "[ERROR] Setup failed. Please check your internet connection and try again."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Environment isolation — keep everything inside the portable folder
# (except the venv, which must live on a local FS to avoid exFAT hardlink
# limitations — see scripts/setup-unix.sh for details)
# ---------------------------------------------------------------------------

# Read the venv path from the pointer file written during setup.
if [ -f "$RUNTIME_DIR/venv.path" ]; then
    VIRTUAL_ENV="$(cat "$RUNTIME_DIR/venv.path")"
else
    # Fallback for older setups that put the venv on the drive.
    VIRTUAL_ENV="$RUNTIME_DIR/venv"
fi

# If the venv is missing (e.g. after a reboot purged $TMPDIR), rebuild it.
if [ ! -x "$VIRTUAL_ENV/bin/python" ]; then
    echo ""
    echo "[INFO] Local venv not found (temp was likely cleared). Rebuilding ..."
    echo "       This is fast because packages are cached on the drive."
    UV_EXE="$RUNTIME_DIR/uv/uv"
    PYTHON_EXE="$RUNTIME_DIR/python/bin/python3"
    SRC_DIR="$PORTABLE_ROOT/src"

    if [ "$PLATFORM" = "macos" ]; then
        LOCAL_BASE="${TMPDIR:-/tmp}"
    else
        LOCAL_BASE="/tmp"
    fi

    DRIVE_ID="$(portable_id "$RUNTIME_DIR")"
    VIRTUAL_ENV="${LOCAL_BASE}/hermes-portable-venv-${DRIVE_ID}"
    export UV_CACHE_DIR="${LOCAL_BASE}/hermes-uv-cache-${DRIVE_ID}"
    mkdir -p "$UV_CACHE_DIR"

    # Save updated path
    echo "$VIRTUAL_ENV" > "$RUNTIME_DIR/venv.path"

    rm -rf "$VIRTUAL_ENV"
    if ! "$UV_EXE" venv "$VIRTUAL_ENV" --python "$PYTHON_EXE" --seed 2>/dev/null; then
        "$UV_EXE" venv "$VIRTUAL_ENV" --python "$PYTHON_EXE"
    fi
    if ! "$UV_EXE" pip install --python "$VIRTUAL_ENV/bin/python" --link-mode=copy \
        -e "$SRC_DIR/hermes-agent[all]" \
        "python-telegram-bot[webhooks]==22.6" 2>/dev/null; then
        "$VIRTUAL_ENV/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
        if ! "$VIRTUAL_ENV/bin/python" -m pip install \
                -e "$SRC_DIR/hermes-agent[all]" \
                "python-telegram-bot[webhooks]==22.6"; then
            echo ""
            echo "[ERROR] Failed to rebuild venv dependencies."
            echo "        Delete .cache and run launch.sh again to restart setup."
            exit 1
        fi
    fi
    echo "[OK]    Venv rebuilt."
fi

export HERMES_HOME="$HERMES_HOME"
export VIRTUAL_ENV
export PATH="$VIRTUAL_ENV/bin:$RUNTIME_DIR/python/bin:$RUNTIME_DIR/node/bin:$RUNTIME_DIR/uv:$RUNTIME_DIR/bin:$PATH"
export PYTHONNOUSERSITE=1
export PYTHONHOME=""
export PYTHONPATH=""
export UV_NO_CONFIG=1
export UV_PYTHON="$RUNTIME_DIR/python/bin/python3"
export PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/playwright"
export NODE_PATH="$RUNTIME_DIR/node/lib/node_modules"
export NPM_CONFIG_PREFIX="$RUNTIME_DIR/node"

# Prevent Node/npm from writing to host home directory
export HOME="$PORTABLE_ROOT/.cache/unix-home"
mkdir -p "$HOME"

# ---------------------------------------------------------------------------
# Launch Hermes
# ---------------------------------------------------------------------------
# Switch off 'errexit' for the interactive menu: a non-zero exit from the
# `hermes` TUI (Ctrl+C, /exit with error, command error) must NOT terminate
# the launcher. Setup/venv above still ran under `set -e` for safety.
set +e

if [ ! -d "$SRC_DIR/hermes-agent" ]; then
    echo "[ERROR] Hermes source not found. Please delete .cache and try again."
    exit 1
fi

cd "$SRC_DIR/hermes-agent" || exit 1

# Strip "hermes" from the start of arguments if user typed "launch.sh hermes setup"
if [ "$1" = "hermes" ] || [ "$1" = "HERMES" ]; then
    shift
fi

# If explicit arguments were passed, run Hermes directly (skip menu)
if [ $# -gt 0 ]; then
    hermes "$@"
    exit $?
fi

# ---------------------------------------------------------------------------
# ANSI Colors
# ---------------------------------------------------------------------------
ESC='\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
CYAN="${ESC}[36m"
BRIGHT_CYAN="${ESC}[96m"
GREEN="${ESC}[32m"
BRIGHT_GREEN="${ESC}[92m"
YELLOW="${ESC}[33m"
BRIGHT_YELLOW="${ESC}[93m"
RED="${ESC}[31m"
BRIGHT_RED="${ESC}[91m"
WHITE="${ESC}[37m"
BRIGHT_WHITE="${ESC}[97m"
GRAY="${ESC}[90m"

# ---------------------------------------------------------------------------
# Status Detection
# ---------------------------------------------------------------------------
detect_status() {
    SETUP_STATUS="Not configured"
    SETUP_ICON="[x]"
    SETUP_COLOR="$RED"
    PROVIDER_NAME=""
    MODEL_NAME=""

    if [ -f "$HERMES_HOME/.env" ] && grep -q '^[A-Z].*=' "$HERMES_HOME/.env"; then
        SETUP_STATUS="Configured"
        SETUP_ICON="[OK]"
        SETUP_COLOR="$BRIGHT_GREEN"
    fi

    if [ -f "$HERMES_HOME/config.yaml" ]; then
        PROVIDER_NAME=$(grep '^  provider:' "$HERMES_HOME/config.yaml" | head -n 1 | awk '{print $2}' | tr -d '"' || true)
        MODEL_NAME=$(grep '^  default:' "$HERMES_HOME/config.yaml" | head -n 1 | awk '{print $2}' | tr -d '"' || true)
    fi

    LLAMA_STATUS="Stopped"
    LLAMA_ICON="[ ]"
    LLAMA_COLOR="$GRAY"
    LLAMA_PID=""
    if [ -f "$HERMES_HOME/llama-server.pid" ]; then
        LLAMA_PID=$(cat "$HERMES_HOME/llama-server.pid" 2>/dev/null || true)
    fi
    if [ -n "$LLAMA_PID" ]; then
        if kill -0 "$LLAMA_PID" 2>/dev/null; then
            LLAMA_STATUS="Running (PID $LLAMA_PID)"
            LLAMA_ICON="[OK]"
            LLAMA_COLOR="$BRIGHT_GREEN"
        else
            LLAMA_STATUS="Stopped"
            rm -f "$HERMES_HOME/llama-server.pid"
        fi
    fi

    GATEWAY_STATUS="Stopped"
    GATEWAY_ICON="[ ]"
    GATEWAY_COLOR="$GRAY"
    GATEWAY_PID=""

    if [ -f "$HERMES_HOME/gateway.pid" ]; then
        GATEWAY_PID=$(grep -o '"pid":[0-9]*' "$HERMES_HOME/gateway.pid" | grep -o '[0-9]*' || true)
    fi

    if [ -n "$GATEWAY_PID" ]; then
        if kill -0 "$GATEWAY_PID" 2>/dev/null; then
            GATEWAY_STATUS="Running (PID $GATEWAY_PID)"
            GATEWAY_ICON="[OK]"
            GATEWAY_COLOR="$BRIGHT_GREEN"
        else
            GATEWAY_STATUS="Stopped (stale lock)"
            GATEWAY_ICON="[!]"
            GATEWAY_COLOR="$YELLOW"
        fi
    fi

    HERMES_VERSION="unknown"
    if [ -f "$SRC_DIR/hermes-agent/hermes_cli/__init__.py" ]; then
        HERMES_VERSION=$(grep '__version__' "$SRC_DIR/hermes-agent/hermes_cli/__init__.py" | head -n 1 | sed 's/.*"\(.*\)".*/\1/')
    fi
}

# ---------------------------------------------------------------------------
# Main Menu
# ---------------------------------------------------------------------------
show_menu() {
    clear
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${BOLD}${BRIGHT_WHITE}                    HERMES PORTABLE LAUNCHER${RESET}"
    echo -e "${DIM}${GRAY}                         AI Agent for Everyone${RESET}"
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    echo -e " ${DIM}Setup${RESET}    ${SETUP_COLOR}${SETUP_ICON}${RESET} ${WHITE}${SETUP_STATUS}${RESET}"
    [ -n "$PROVIDER_NAME" ] && echo -e " ${DIM}Provider${RESET} ${CYAN}${PROVIDER_NAME}${RESET}"
    [ -n "$MODEL_NAME" ] && echo -e " ${DIM}Model${RESET}    ${WHITE}${MODEL_NAME}${RESET}"
    echo -e " ${DIM}Gateway${RESET}  ${GATEWAY_COLOR}${GATEWAY_ICON}${RESET} ${WHITE}${GATEWAY_STATUS}${RESET}"
    [ "$PROVIDER_NAME" = "custom" ] && echo -e " ${DIM}Llama Srv${RESET} ${LLAMA_COLOR}${LLAMA_ICON}${RESET} ${WHITE}${LLAMA_STATUS}${RESET}"
    echo -e " ${DIM}Version${RESET}  ${GRAY}v${HERMES_VERSION}${RESET}"
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    echo -e "  ${BRIGHT_YELLOW}[1]${RESET}  ${WHITE}Start Hermes Chat${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[D]${RESET}  ${WHITE}Start Hermes Desktop${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[2]${RESET}  ${WHITE}Setup / Reconfigure Hermes${RESET}"
    if [ "$GATEWAY_STATUS" = "Running (PID $GATEWAY_PID)" ]; then
        echo -e "  ${BRIGHT_YELLOW}[3]${RESET}  ${WHITE}Stop Gateway${RESET}  ${RED}[live]${RESET}"
    else
        echo -e "  ${BRIGHT_YELLOW}[3]${RESET}  ${WHITE}Start Gateway${RESET}"
    fi
    echo -e "  ${BRIGHT_YELLOW}[4]${RESET}  ${WHITE}Advanced Options${RESET}  ${GRAY}-->${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[L]${RESET}  ${WHITE}Setup Local LLM (llama.cpp)${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[5]${RESET}  ${GRAY}Exit${RESET}"
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    read -p "$(echo -e "${BRIGHT_CYAN}Select option: ${RESET}")" choice

    case "$choice" in
        1) menu_chat ;;
        [dD]) menu_desktop ;;
        2) menu_setup ;;
        3) menu_gateway ;;
        4) show_advanced ;;
        [lL]) menu_local_setup ;;
        5) menu_exit ;;
        *) show_menu ;;
    esac
}

menu_chat() {
    clear
    ensure_llama_server || return
    hermes
    stop_llama_server
    detect_status
    show_menu
}

menu_desktop() {
    clear
    ensure_llama_server || return
    echo -e "${CYAN}Starting Hermes Desktop app ...${RESET}"
    hermes desktop
    stop_llama_server
    detect_status
    show_menu
}

menu_setup() {
    clear
    hermes setup
    detect_status
    show_menu
}

menu_gateway() {
    if [ "$GATEWAY_STATUS" = "Running (PID $GATEWAY_PID)" ]; then
        hermes gateway stop
        stop_llama_server
        echo ""
        echo -e "${BRIGHT_GREEN}Gateway stopped.${RESET}"
    else
        echo ""
        ensure_llama_server || return
        echo -e "${CYAN}Starting gateway in background ...${RESET}"
        hermes gateway &
        sleep 2
    fi
    read -p "Press Enter to continue ..."
    detect_status
    show_menu
}

menu_local_setup() {
    clear
    echo ""
    "$VIRTUAL_ENV/bin/python" "$PORTABLE_ROOT/scripts/local_setup_server.py"
    detect_status
    show_menu
}

menu_exit() {
    clear
    if [ "$GATEWAY_STATUS" != "Running (PID $GATEWAY_PID)" ]; then
        stop_llama_server
    fi
    echo ""
    echo -e "${GRAY}Goodbye!${RESET}"
    echo ""
    exit 0
}

ensure_llama_server() {
    if [ "$PROVIDER_NAME" = "custom" ]; then
        if [ -f "$HERMES_HOME/config.yaml" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' 's/127.0.0.1:11434\/v1/127.0.0.1:39600\/v1/g' "$HERMES_HOME/config.yaml" 2>/dev/null || true
                sed -i '' 's/localhost:11434\/v1/127.0.0.1:39600\/v1/g' "$HERMES_HOME/config.yaml" 2>/dev/null || true
            else
                sed -i 's/127.0.0.1:11434\/v1/127.0.0.1:39600\/v1/g' "$HERMES_HOME/config.yaml" 2>/dev/null || true
                sed -i 's/localhost:11434\/v1/127.0.0.1:39600\/v1/g' "$HERMES_HOME/config.yaml" 2>/dev/null || true
            fi
        fi
        LLAMA_PID=""
        if [ -f "$HERMES_HOME/llama-server.pid" ]; then
            LLAMA_PID=$(cat "$HERMES_HOME/llama-server.pid" 2>/dev/null || true)
        fi
        RUNNING=""
        if [ -n "$LLAMA_PID" ] && kill -0 "$LLAMA_PID" 2>/dev/null; then
            RUNNING="1"
        fi
        if [ -z "$RUNNING" ]; then
            echo -e "${CYAN}Starting local llama-server in background ...${RESET}"
            
            MODEL_FILE=""
            if [ -f "$HERMES_HOME/config.yaml" ]; then
                MODEL_FILE=$(grep '^  default:' "$HERMES_HOME/config.yaml" | head -n 1 | awk '{print $2}' | sed 's/custom\///' | sed 's/"//g' || true)
            fi
            
            MODEL_PATH=""
            if [ -n "$MODEL_FILE" ]; then
                if [ -f "$HERMES_HOME/models/$MODEL_FILE" ]; then
                    MODEL_PATH="$HERMES_HOME/models/$MODEL_FILE"
                else
                    MODEL_PATH=$(find "$HERMES_HOME/models" -name "$MODEL_FILE" 2>/dev/null | head -n 1 || true)
                fi
            fi
            
            if [ -z "$MODEL_PATH" ]; then
                echo -e "${YELLOW}Warning: Configured model not found or not specified. Fallback to first GGUF found.${RESET}"
                MODEL_PATH=$(find "$HERMES_HOME/models" -name "*.gguf" 2>/dev/null | head -n 1 || true)
            fi
            
            if [ -z "$MODEL_PATH" ]; then
                echo -e "${RED}Error: No GGUF model file configured or found. Run [L] to configure.${RESET}"
                read -p "Press Enter to return ..."
                detect_status
                show_menu
                return 1
            fi
            
            SERVER_EXE="$PORTABLE_ROOT/.cache/runtimes/llama-server/llama-server"
            if [ ! -f "$SERVER_EXE" ]; then
                echo -e "${RED}Error: llama-server executable not found at $SERVER_EXE. Run [L] to setup.${RESET}"
                read -p "Press Enter to return ..."
                detect_status
                show_menu
                return 1
            fi
            
            # Start server in background
            chmod +x "$SERVER_EXE" 2>/dev/null || true
            mkdir -p "$HERMES_HOME/logs"
            CTX_LEN=$(grep -E "^[[:space:]]*context_length:" "$HERMES_HOME/config.yaml" | awk '{print $2}' | tr -d '"')
            if [ -z "$CTX_LEN" ]; then
                CTX_LEN=32768
            fi
            "$SERVER_EXE" -m "$MODEL_PATH" -c $CTX_LEN -np 1 --port 39600 --host 127.0.0.1 --jinja --no-warmup > "$HERMES_HOME/logs/llama-server.log" 2>&1 &
            NEW_LLAMA_PID=$!
            
            if [ -n "$NEW_LLAMA_PID" ]; then
                echo "$NEW_LLAMA_PID" > "$HERMES_HOME/llama-server.pid"
                echo -e "${BRIGHT_GREEN}llama-server started (PID $NEW_LLAMA_PID).${RESET}"
                sleep 3
            else
                echo -e "${RED}Error: Failed to start llama-server.${RESET}"
                read -p "Press Enter to return ..."
                detect_status
                show_menu
                return 1
            fi
        fi
    fi
    return 0
}

stop_llama_server() {
    if [ -f "$HERMES_HOME/llama-server.pid" ]; then
        LLAMA_PID=$(cat "$HERMES_HOME/llama-server.pid" 2>/dev/null || true)
        if [ -n "$LLAMA_PID" ]; then
            kill -9 "$LLAMA_PID" 2>/dev/null || true
            echo -e "${CYAN}Stopped local llama-server.${RESET}"
        fi
        rm -f "$HERMES_HOME/llama-server.pid"
    fi
}

# ---------------------------------------------------------------------------
# Advanced Menu
# ---------------------------------------------------------------------------
show_advanced() {
    clear
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${BOLD}${BRIGHT_WHITE}                       Advanced Options${RESET}"
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    echo -e "  ${BRIGHT_YELLOW}[1]${RESET}  ${WHITE}Run Doctor${RESET}            ${GRAY}- check for issues${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[2]${RESET}  ${WHITE}View Logs${RESET}             ${GRAY}- last 20 lines${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[3]${RESET}  ${WHITE}Edit Config${RESET}           ${GRAY}- open in editor${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[4]${RESET}  ${WHITE}Restart Gateway${RESET}       ${GRAY}- stop + start${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[5]${RESET}  ${WHITE}Update Hermes${RESET}         ${GRAY}- fetch latest${RESET}"
    echo -e "  ${BRIGHT_YELLOW}[6]${RESET}  ${GRAY}Back to Main Menu${RESET}"
    echo ""
    echo -e "${BRIGHT_CYAN}----------------------------------------------------------------${RESET}"
    echo ""
    read -p "$(echo -e "${BRIGHT_CYAN}Select option: ${RESET}")" choice

    case "$choice" in
        1) adv_doctor ;;
        2) adv_logs ;;
        3) adv_config ;;
        4) adv_restart ;;
        5) adv_update ;;
        6) show_menu ;;
        *) show_advanced ;;
    esac
}

adv_doctor() {
    clear
    hermes doctor
    read -p "Press Enter to continue ..."
    show_advanced
}

adv_logs() {
    clear
    if [ -f "$HERMES_HOME/logs/gateway.log" ]; then
        echo -e "${CYAN}=== Gateway Log (last 20 lines) ===${RESET}"
        tail -n 20 "$HERMES_HOME/logs/gateway.log"
    else
        echo -e "${YELLOW}No logs found.${RESET}"
    fi
    echo ""
    read -p "Press Enter to continue ..."
    show_advanced
}

adv_config() {
    clear
    hermes config edit
    show_advanced
}

adv_restart() {
    hermes gateway restart
    echo ""
    echo -e "${BRIGHT_GREEN}Gateway restarted.${RESET}"
    read -p "Press Enter to continue ..."
    detect_status
    show_menu
}

adv_update() {
    clear
    hermes update
    read -p "Press Enter to continue ..."
    show_advanced
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
detect_status
show_menu
