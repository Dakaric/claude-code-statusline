#!/usr/bin/env bash
# Mails sind bekannt, aber kein Handler installiert und keine Variable gesetzt: kein
# Link. Die Ausgabe muss exakt der von zwei-accounts entsprechen.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com b@example.com
