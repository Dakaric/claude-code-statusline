#!/usr/bin/env bash
# B ist frisch zurueckgesetzt und hat damit die niedrigere Verfallsrate. Der Pfeil muss
# trotzdem kommen, weil As 5h-Fenster bei 97 Prozent steht.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 0 -1 0 -3600
