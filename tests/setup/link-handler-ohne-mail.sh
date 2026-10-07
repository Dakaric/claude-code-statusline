#!/usr/bin/env bash
# Wie link-handler-ziel, aber die Snapshots stammen von einer Version ohne Mail: das
# Wechselsignal verlinkt dann auf die Rotation statt auf ein Ziel.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600
mark_switch_handler "$1"
