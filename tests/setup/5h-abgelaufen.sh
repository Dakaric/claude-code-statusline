#!/usr/bin/env bash
# Wie 5h-aus-snapshot, nur ist auch im Snapshot das 5h-Fenster schon vorbei und noch
# kein neues begonnen: dann ist es frei, wie bei jedem anderen Account.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 78 77760 40 -3600
write_snapshot "$1" "$ACCT_A" "$((now - 100))" "$((now - 600))" \
  24 "$((now + 448800))" 12 "$((now - 60))"
