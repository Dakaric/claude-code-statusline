#!/usr/bin/env bash
# Parallele Sessions melden im selben Fenster abwechselnd aeltere und neuere Staende,
# die Historie springt zwischen 20 und 22. Verbraucht sind aber nur 4 Punkte (20 auf 24),
# ein Rueckgang ohne neuen Reset ist kein Reset. Also Tempo unter der Nachfuellrate.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 50 475200 0 -3600
write_history_a "$1" "$now" 448800 \
  -86000 20 -80000 22 -70000 20 -60000 22 -50000 20 -40000 22 -30000 20 -600 24
