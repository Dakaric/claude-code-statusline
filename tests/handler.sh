#!/usr/bin/env bash
# Tests für den Klick-Handler gegen einen cswap-Fake. Der Handler wird aus install.sh
# herausgelöst und mit einem Kopf versehen, wie install.sh ihn schreibt.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
failed=0
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT

mkdir -p "$sb/bin" "$sb/cswap"
for tool in bash cat; do ln -s "$(command -v "$tool")" "$sb/bin/$tool"; done
for tool in uname osascript notify-send; do ln -s "$root/tests/fakes/$tool" "$sb/bin/$tool"; done
{
  printf '#!/usr/bin/env bash\n'
  printf 'CSWAP_BIN=%q\nJQ_BIN=%q\n' "$root/tests/fakes/cswap" "$(command -v jq)"
  bash "$root/tests/extract-handler.sh"
} > "$sb/handler.sh"

cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[
  {"number":1,"email":"a@example.com","active":true},
  {"number":2,"email":"b@example.com","active":false}]}
JSON
printf '{"schemaVersion":1,"switched":true,"message":"Switched to Account-2 (b@example.com)"}\n' \
  > "$sb/cswap/switch.json"

# run_handler URL: setzt rc, leert das Log vorher. FAKE_UNAME wählt den Mitteilungsweg.
run_handler() {
  : > "$sb/log"
  env -i PATH="$sb/bin" FAKE_LOG="$sb/log" FAKE_CSWAP_DIR="$sb/cswap" \
    FAKE_UNAME="${FAKE_UNAME:-Darwin}" FAKE_FAIL="${FAKE_FAIL:-}" \
    "$BASH" "$sb/handler.sh" "$1" > "$sb/out" 2>&1
  rc=$?
}

expect() {
  local name=$1 url=$2 want_rc=$3 want_log=$4 deny_log=${5:-}
  run_handler "$url"
  if [ "$rc" != "$want_rc" ]; then
    printf 'FEHLER handler %s: Exit %s, erwartet %s\n' "$name" "$rc" "$want_rc"; cat "$sb/log"; failed=1
  elif [ -n "$want_log" ] && ! grep -qF -- "$want_log" "$sb/log"; then
    printf 'FEHLER handler %s: "%s" fehlt im Log\n' "$name" "$want_log"; cat "$sb/log"; failed=1
  # Verbote gelten nur für Aufrufe: jede Fake-Zeile beginnt mit dem Werkzeugnamen. So
  # stört der Wortlaut einer Mitteilung im osascript-Log die Prüfung nicht.
  elif [ -n "$deny_log" ] && grep -q -- "^$deny_log" "$sb/log"; then
    printf 'FEHLER handler %s: "%s" darf nicht im Log stehen\n' "$name" "$deny_log"; cat "$sb/log"; failed=1
  else
    printf 'ok     handler (%s)\n' "$name"
  fi
}

expect "gültiges Ziel" 'claude-statusline://switch?to=b%40example.com' 0 'cswap switch 2 --json'
expect "Ziel ohne Rücksicht auf Groß- und Kleinschreibung" \
  'claude-statusline://switch?to=B%40Example.com' 0 'cswap switch 2 --json'
expect "Mitteilung trägt cswaps Meldung" 'claude-statusline://switch?to=b%40example.com' 0 \
  'Switched to Account-2 (b@example.com)'
expect "Rotation" 'claude-statusline://switch' 0 'cswap switch --json' 'cswap list'
expect "unbekanntes Ziel" 'claude-statusline://switch?to=c%40example.com' 2 'is not an account managed' 'cswap switch'
expect "fremdes Schema" 'https://evil.example/switch' 2 '' 'cswap'
expect "angehängter Parameter" 'claude-statusline://switch?to=b%40example.com&x=1' 2 '' 'cswap switch'
expect "anderer Pfad" 'claude-statusline://switch/x' 2 '' 'cswap'
expect "leeres Ziel" 'claude-statusline://switch?to=' 2 '' 'cswap switch'
expect "Zeilenumbruch im Ziel" 'claude-statusline://switch?to=%0Ab%40example.com' 2 '' 'cswap switch'
expect "Nullbyte im Ziel" 'claude-statusline://switch?to=b%40example.com%00' 2 '' 'cswap switch'
expect "doppeltes Ziel" 'claude-statusline://switch?to=b%40example.com?to=a%40example.com' 2 '' 'cswap switch'
expect "Fragment" 'claude-statusline://switch?to=b%40example.com#x' 2 '' 'cswap switch'

cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[
  {"number":1,"email":"a@example.com"},{"number":3,"email":"a+b@example.com"}]}
JSON
expect "Plus in der Mail" 'claude-statusline://switch?to=a%2Bb%40example.com' 0 'cswap switch 3 --json'

printf '1\n' > "$sb/cswap/list.exit"
expect "cswap list scheitert" 'claude-statusline://switch?to=a%40example.com' 2 'Could not read the accounts' 'cswap switch'
rm -f "$sb/cswap/list.exit"

cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[
  {"number":1,"email":"b@example.com"},{"number":2,"email":"b@example.com"}]}
JSON
expect "mehrdeutige Mail" 'claude-statusline://switch?to=b%40example.com' 2 'more than one' 'cswap switch'

printf '{"schemaVersion":1,"error":{"type":"X","message":"No account found with identifier: 9"}}\n' \
  > "$sb/cswap/switch.json"
printf '1\n' > "$sb/cswap/switch.exit"
expect "cswap-Fehler wird gemeldet" 'claude-statusline://switch' 0 'No account found with identifier: 9'

FAKE_UNAME=Linux expect "Mitteilung unter Linux" 'claude-statusline://switch' 0 'notify-send Claude Statusline'
rm -f "$sb/bin/notify-send"
FAKE_UNAME=Linux run_handler 'claude-statusline://switch'
if grep -q 'No account found' "$sb/out"; then printf 'ok     handler (ohne notify-send auf stderr)\n'
else printf 'FEHLER handler ohne notify-send: keine Meldung auf stderr\n'; failed=1; fi

FAKE_FAIL=osascript run_handler 'claude-statusline://switch'
if grep -q '^Claude Statusline: ' "$sb/out"; then printf 'ok     handler (scheitert osascript, steht die Meldung auf stderr)\n'
else printf 'FEHLER handler: osascript scheitert und die Meldung geht verloren\n'; failed=1; fi

# cswap rollt einen abgebrochenen Tausch nicht zurück: kein Timeout, kein kill, kein
# Hintergrundlauf im Handler. Geprüft wird nur Code, nicht Kommentare; ohne Rumpf ist
# das ein Fehler, kein stilles ok.
if ! body=$(bash "$root/tests/extract-handler.sh"); then
  printf 'FEHLER handler: kein Rumpf zum Prüfen\n'; failed=1
elif printf '%s\n' "$body" | grep -v '^[[:space:]]*#' \
    | grep -nE '\btimeout\b|\bkill\b|\bnohup\b|\bdisown\b|&[[:space:]]*($|;)'; then
  printf 'FEHLER handler: Timeout, kill oder Hintergrundlauf im Handler\n'; failed=1
else
  printf 'ok     handler (cswap switch wird nie abgebrochen)\n'
fi

exit "$failed"
