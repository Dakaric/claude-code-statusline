#!/usr/bin/env bash
# Handler installiert und Variable gesetzt: die Variable gewinnt. Die Ausgabe muss exakt
# der von link-signal entsprechen.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com b@example.com
mark_switch_handler "$1"
