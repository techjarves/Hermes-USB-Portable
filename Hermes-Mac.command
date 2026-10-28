#!/bin/bash
# Hermes Portable - double-click this file in Finder (macOS).
# Finder opens it in Terminal and starts the launcher from this drive,
# exactly like running ./launch.sh in a terminal.
cd "$(dirname "$0")" || exit 1
export HERMES_IN_TERMINAL=1
exec bash ./launch.sh "$@"
