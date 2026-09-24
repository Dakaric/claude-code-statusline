#!/usr/bin/env bash
# A's Snapshot traegt B's Fenster, geschrieben von einer aelteren Version, die den Stand
# dem Login zuschrieb. Zwei Accounts mit demselben Reset heissen: einer davon ist falsch,
# und falsch sein kann nur der Login, denn nur er bekommt fremde Staende zugeschrieben.
# A's echter Payload muss den Snapshot deshalb ersetzen, obwohl dessen Fenster noch
# nicht vorbei ist.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 7 501120 1 7200
write_snapshot "$1" "$ACCT_A" "$((now - 100))" "$((now - 600))" \
  7 "$((now + 501120))" 1 "$((now + 7200))"
