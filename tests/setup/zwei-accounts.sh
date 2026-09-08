#!/usr/bin/env bash
# Grundfall zweier Accounts. Die Konstellation deckt zugleich den Verfalls-Ausloeser des
# Wechselsignals ab: bei B laufen 22 Punkte in 0,9 Tagen ab, bei A 76 in 5,2 Tagen, also
# muss der Pfeil nach B zeigen.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600
