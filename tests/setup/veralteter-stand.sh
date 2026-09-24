#!/usr/bin/env bash
# Zwei Sessions auf B, eine davon hat ihre letzte Antwort vor einer Weile bekommen und
# meldet 4 %, der Snapshot kennt schon 6 %. Im selben Fenster sinkt der Verbrauch nie,
# der aeltere Stand darf den neueren also nicht ueberschreiben.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 6 501120 3 7200
write_snapshot "$1" "$ACCT_A" "$((now - 100))" "$((now - 600))" \
  43 "$((now + 293760))" 10 "$((now + 3600))"
