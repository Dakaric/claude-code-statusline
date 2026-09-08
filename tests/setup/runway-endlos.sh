#!/usr/bin/env bash
# Tempo unter der Nachfuellrate: 10 Punkte in 24 Stunden, das Budget laeuft nie leer.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 78 77760 40 -3600
write_history_a "$1" "$now" -86400 0 -43200 5 -600 10
