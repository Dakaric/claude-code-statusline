#!/usr/bin/env bash
# Wie link-handler-ziel, aber Bs Mail enthaelt ein Leerzeichen, das der Handler abweisen
# wuerde: der Link bleibt die Rotation, ohne Ziel.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com 'a b@ex.com'
mark_switch_handler "$1"
