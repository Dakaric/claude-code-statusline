#!/usr/bin/env bash
# Tests für den Klick-Handler gegen einen cswap-Fake. Der Handler wird aus install.sh
# herausgelöst und mit einem Kopf versehen, wie install.sh ihn schreibt.
set -u

root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd) || exit 1
failed=0
sb=$(mktemp -d) || exit 1
trap 'rm -rf -- "$sb"' EXIT

mkdir -p "$sb/bin" "$sb/cswap" "$sb/with space"
for tool in bash cat ln rm rmdir mkdir readlink dirname; do ln -s "$(command -v "$tool")" "$sb/bin/$tool"; done
for tool in uname osascript notify-send; do ln -s "$root/tests/fakes/$tool" "$sb/bin/$tool"; done

# Der Handler entsteht über write_switch_handler aus install.sh, nicht über einen
# nachgebauten Kopf. Der Pfad mit Leerzeichen prüft die %q-Maskierung mit.
cswap_path="$sb/with space/cswap"
cp "$root/tests/fakes/cswap" "$cswap_path"
jq_path=$(command -v jq)
# shellcheck disable=SC2034,SC2317,SC2329  # HANDLER_PATH, STATE_DIR und die() liest write_switch_handler
(
  HANDLER_PATH="$sb/handler.sh"
  STATE_DIR="$sb"
  die() { printf 'handler: %s\n' "$*" >&2; exit 1; }
  eval "$(sed '$d' "$root/install.sh")"
  write_switch_handler "$cswap_path" "$jq_path"
) || { printf 'FEHLER handler: write_switch_handler scheitert\n'; exit 1; }

lock_path="$sb/switch.lock"
want_head=$(printf '#!/usr/bin/env bash\nCSWAP_BIN=%q\nJQ_BIN=%q\nLOCK_PATH=%q' "$cswap_path" "$jq_path" "$lock_path")
if [ "$(sed -n '1,4p' "$sb/handler.sh")" = "$want_head" ]; then printf 'ok     handler (Kopf aus write_switch_handler)\n'
else printf 'FEHLER handler: Kopf weicht ab\n'; sed -n '1,4p' "$sb/handler.sh"; failed=1; fi
if [ -x "$sb/handler.sh" ]; then printf 'ok     handler (ausführbar)\n'
else printf 'FEHLER handler: Datei nicht ausführbar\n'; failed=1; fi

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
expect "Schrägstrich kodiert" 'claude-statusline://switch?to=b%2Fx%40example.com' 2 '' 'cswap switch'
expect "Backslash kodiert" 'claude-statusline://switch?to=b%5Cx%40example.com' 2 '' 'cswap switch'
expect "Leerzeichen kodiert" 'claude-statusline://switch?to=b%20x%40example.com' 2 '' 'cswap switch'
expect "Schema in Großbuchstaben" 'CLAUDE-STATUSLINE://switch' 2 '' 'cswap'
expect "doppelt kodiert" 'claude-statusline://switch?to=b%2540example.com' 2 '' 'cswap switch'
expect "Ziel ohne Mail" 'claude-statusline://switch?to=%40' 2 '' 'cswap switch'

cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[
  {"number":1,"email":"a@example.com"},{"number":3,"email":"a+b@example.com"}]}
JSON
expect "Plus in der Mail" 'claude-statusline://switch?to=a%2Bb%40example.com' 0 'cswap switch 3 --json'

printf '{"schemaVersion":2,"accounts":[{"number":2,"email":"b@example.com"}]}\n' > "$sb/cswap/list.json"
expect "unbekannte Schemaversion von cswap list" 'claude-statusline://switch?to=b%40example.com' 2 'Could not read the accounts' 'cswap switch'
cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[
  {"number":1,"email":"a@example.com"},{"number":3,"email":"a+b@example.com"}]}
JSON

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

FAKE_UNAME=Linux expect "Mitteilung unter Linux" 'claude-statusline://switch' 0 'notify-send -- Claude Statusline'
rm -f "$sb/bin/notify-send"
FAKE_UNAME=Linux run_handler 'claude-statusline://switch'
if grep -q 'No account found' "$sb/out"; then printf 'ok     handler (ohne notify-send auf stderr)\n'
else printf 'FEHLER handler ohne notify-send: keine Meldung auf stderr\n'; failed=1; fi

FAKE_FAIL=osascript run_handler 'claude-statusline://switch'
if [ "$rc" = 0 ] && grep -q '^Claude Statusline: ' "$sb/out"; then printf 'ok     handler (scheitert osascript, steht die Meldung auf stderr)\n'
else printf 'FEHLER handler: osascript scheitert und die Meldung geht verloren\n'; failed=1; fi

FAKE_FAIL=osascript run_handler 'https://evil.example/switch'
if [ "$rc" = 2 ] && grep -q '^Claude Statusline: ' "$sb/out"; then printf 'ok     handler (scheitert osascript bei Abweisung, Exit 2)\n'
else printf 'FEHLER handler: Abweisung bei scheiternder Mitteilung, Exit %s\n' "$rc"; failed=1; fi

# cswap rollt einen abgebrochenen Tausch nicht zurück: kein Timeout, kein kill, kein
# Hintergrundlauf im Handler. kill -0 sendet kein Signal und prüft nur, ob die PID der
# Sperre lebt; es ist erlaubt. Geprüft wird nur Code, nicht Kommentare; ohne Rumpf ist
# das ein Fehler, kein stilles ok.
if ! body=$(bash "$root/tests/extract-handler.sh"); then
  printf 'FEHLER handler: kein Rumpf zum Prüfen\n'; failed=1
elif printf '%s\n' "$body" | grep -v '^[[:space:]]*#' | grep -v 'kill -0' \
    | grep -nE '\btimeout\b|\bkill\b|\bnohup\b|\bdisown\b|&[[:space:]]*($|;)'; then
  printf 'FEHLER handler: Timeout, kill oder Hintergrundlauf im Handler\n'; failed=1
else
  printf 'ok     handler (cswap switch wird nie abgebrochen)\n'
fi

# Signale an die Prozessgruppe dürfen cswap switch nicht erreichen: das trap steht vor
# jedem Aufruf von switch, geprüft an der Zeilenfolge des Rumpfs.
trap_line=$(printf '%s\n' "$body" | grep -n "^[[:space:]]*trap '' HUP INT TERM" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016  # der Text steht wörtlich im Rumpf
switch_call='"$CSWAP_BIN" switch'
first_switch=$(printf '%s\n' "$body" | grep -nF "$switch_call" | head -1 | cut -d: -f1)
if [ -n "$trap_line" ] && [ -n "$first_switch" ] && [ "$trap_line" -lt "$first_switch" ]; then
  printf 'ok     handler (HUP, INT und TERM ignoriert vor cswap switch)\n'
else
  printf 'FEHLER handler: trap fehlt oder steht nach cswap switch\n'; failed=1
fi

# Gegenseitiger Ausschluss: Die Sperre ist ein Symlink, dessen Ziel die PID des Besitzers
# ist. Entfernt wird sie nur vom Besitzer. Ein zweiter Klick während eines Wechsels wird
# abgewiesen, ohne zu warten und ohne cswap switch. Bleibt eine Sperre eines toten Besitzers
# liegen (kill -9, Stromausfall), wird sie nie automatisch übernommen: cswap rollt einen
# halben Wechsel nicht zurück, der Anwender soll nachsehen.
lock_exists() { [ -e "$lock_path" ] || [ -L "$lock_path" ]; }
no_lock_left() {
  if lock_exists; then printf 'FEHLER handler: %s: Sperre bleibt liegen\n' "$1"; failed=1
  else printf 'ok     handler (%s: keine Sperre danach)\n' "$1"; fi
}
lock_untouched() {
  if [ "$(readlink "$lock_path" 2>/dev/null)" = "$2" ]; then printf 'ok     handler (%s: Sperre unangetastet)\n' "$1"
  else printf 'FEHLER handler: %s: Sperre verändert\n' "$1"; failed=1; fi
}
sleep 0 & dead_pid=$!; wait "$dead_pid"

ln -s "$$" "$lock_path"
expect "belegte Sperre mit lebender PID" 'claude-statusline://switch' 2 'A switch is already running.' 'cswap switch'
lock_untouched "lebender Besitzer" "$$"
rm -f "$lock_path"

ln -s "$dead_pid" "$lock_path"
expect "Sperre eines toten Besitzers" 'claude-statusline://switch' 2 'The previous switch did not finish.' 'cswap switch'
lock_untouched "toter Besitzer" "$dead_pid"
rm -f "$lock_path"

ln -s "keine-pid" "$lock_path"
expect "Sperre mit unlesbarem Besitzer" 'claude-statusline://switch' 2 'The previous switch did not finish.' 'cswap switch'
lock_untouched "unlesbarer Besitzer" "keine-pid"
rm -f "$lock_path"

mkdir "$lock_path"
expect "Ordner am Sperrpfad" 'claude-statusline://switch' 2 'A switch is already running.' 'cswap switch'
# rmdir gelingt nur an einem leeren Ordner: kein Link im Ordner, der Ordner selbst da.
if [ ! -L "$lock_path" ] && rmdir "$lock_path" 2>/dev/null; then printf 'ok     handler (Ordner am Sperrpfad unangetastet)\n'
else printf 'FEHLER handler: Ordner am Sperrpfad verändert\n'; failed=1; rm -f "$lock_path"/*; rmdir "$lock_path" 2>/dev/null; fi

expect "Erfolg" 'claude-statusline://switch' 0 'cswap switch --json'
no_lock_left "Erfolg"
cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[{"number":1,"email":"a@example.com"},{"number":2,"email":"b@example.com"}]}
JSON
expect "Ziel mit Erfolg" 'claude-statusline://switch?to=b%40example.com' 0 'cswap switch 2 --json'
no_lock_left "Ziel"
expect "abgewiesener Link" 'https://evil.example/switch' 2 '' 'cswap'
no_lock_left "abgewiesener Link"
expect "unbekanntes Ziel" 'claude-statusline://switch?to=c%40example.com' 2 'is not an account managed' 'cswap switch'
no_lock_left "unbekanntes Ziel"
printf '1\n' > "$sb/cswap/switch.exit"
expect "cswap-Fehler" 'claude-statusline://switch' 0 'cswap switch --json'
no_lock_left "cswap-Fehler"
rm -f "$sb/cswap/switch.exit"
FAKE_UNAME=Linux expect "Sperre auch unter Linux" 'claude-statusline://switch' 0 'cswap switch --json'
no_lock_left "Linux"

exit "$failed"
