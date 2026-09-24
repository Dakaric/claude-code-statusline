#!/usr/bin/env bash
# Das Tempo liegt ueber der Nachfuellrate, die Runway ist also endlich. Trotzdem verfaellt
# Budget: B hat noch 90 Punkte und nur einen Tag. Das Soll-Tempo ist 90 am Tag, bei 40
# Ist bleibt eine Luft von 50.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 10 86400 0 -3600
write_history_a "$1" "$now" 448800 -86000 0 -43000 20 -600 40
