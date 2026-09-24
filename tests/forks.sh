#!/usr/bin/env bash
# Waechtertest fuer die Prozesslast: jede offene Session ruft das Skript jede Sekunde auf,
# jeder jq-Aufruf ist ein eigener Prozess. Mit einem Dutzend Sessions summiert sich das
# zu Hunderten Starts pro Sekunde, und die Maschine erstickt an ihrer eigenen Statusline.
# Ein vorgeschalteter jq zaehlt die Aufrufe eines Laufs im vollen Zwei-Account-Fall.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
test_now=1788870000
max_jq_calls=6
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

real_jq=$(command -v jq)
mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/jq" <<SHIM
#!/usr/bin/env bash
echo x >> "$sandbox/jq-calls"
exec "$real_jq" "\$@"
SHIM
chmod +x "$sandbox/bin/jq"

HOME="$sandbox" STATUSLINE_NOW="$test_now" \
  bash "$root/tests/setup/runway-knapp.sh" "$sandbox" >/dev/null
: > "$sandbox/jq-calls"
HOME="$sandbox" PATH="$sandbox/bin:$PATH" NO_COLOR=1 STATUSLINE_NOW="$test_now" \
  env -u ENABLE_PROMPT_CACHING_1H bash "$root/statusline.sh" \
  < "$root/tests/fixtures/runway-knapp.json" >/dev/null

jq_calls=$(wc -l < "$sandbox/jq-calls" | tr -d ' ')
if [ "$jq_calls" -gt "$max_jq_calls" ]; then
  printf 'FEHLER forks: %d jq-Aufrufe pro Lauf, erlaubt sind %d\n' "$jq_calls" "$max_jq_calls"
  exit 1
fi
printf 'ok     forks (%d jq-Aufrufe pro Lauf)\n' "$jq_calls"
