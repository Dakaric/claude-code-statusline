#!/usr/bin/env bash
# Wie wechsel-verfall, aber Bs 5h-Fenster laeuft noch und steht bei 96 Prozent. Der
# Wechsel braeuchte dort Kapazitaet, also darf kein Pfeil erscheinen.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 96 7200
