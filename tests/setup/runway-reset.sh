#!/usr/bin/env bash
# Mitten in den 24 Stunden setzt A's Wochenfenster zurueck: 90 auf 98 im alten Fenster,
# dann 5 auf 24 im neuen. Der Sprung nach unten traegt einen neuen Reset und zaehlt
# deshalb mit seinem Stand: 8 + 5 + 19 = 32 Punkte, knapp ueber der Nachfuellrate.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 50 475200 0 -3600
write_history_a "$1" "$now" 448800 -20000 5 -600 24
old_window=$((now - 30000))
printf '{"t":%d,"u":90,"r":%d}\n{"t":%d,"u":98,"r":%d}\n' \
  "$((now - 80000))" "$old_window" "$((now - 40000))" "$old_window" \
  >> "$1/.claude/statusline-accounts/${ACCT_A}.history"
