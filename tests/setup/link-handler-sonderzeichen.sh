#!/usr/bin/env bash
# Wie link-handler-ziel, aber Bs Mail traegt Zeichen, die kodiert werden muessen: das Ziel
# steht @uri-kodiert im Link.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com 'x+y%z~@ex.com'
mark_switch_handler "$1"
