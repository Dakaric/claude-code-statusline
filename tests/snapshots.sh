#!/usr/bin/env bash
# Robustheit der Account-Snapshots gegen Dateien, die nicht so aussehen wie erwartet.
#
# first_seen: Die Labels A, B, C folgen first_seen. Scheitert das Lesen eines
# vorhandenen Snapshots, etwa weil ein ueberlasteter Rechner den Lauf mittendrin
# abbricht, darf der Lauf den Snapshot nicht mit first_seen = jetzt neu anlegen: sonst
# tauschen A und B die Plaetze.
#
# Streudateien: Eine leere oder kaputte *.json im Ordner darf das Schreiben der echten
# Snapshots nicht blockieren, sonst friert der Stand jedes Accounts dauerhaft ein.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
test_now=1788870000
acct_a="aaaaaaaa-0000-0000-0000-000000000001"
failed=0

run_statusline() {
  local sandbox=$1 fixture=$2
  HOME="$sandbox" NO_COLOR=1 STATUSLINE_NOW="$test_now" \
    env -u ENABLE_PROMPT_CACHING_1H bash "$root/statusline.sh" \
    < "$root/tests/fixtures/$fixture.json" >/dev/null
}

check_first_seen_survives_unreadable_snapshot() {
  local sandbox snapshot seen_before seen_after
  sandbox=$(mktemp -d)
  snapshot="$sandbox/.claude/statusline-accounts/$acct_a.json"
  HOME="$sandbox" STATUSLINE_NOW="$test_now" \
    bash "$root/tests/setup/vergifteter-snapshot.sh" "$sandbox" >/dev/null
  seen_before=$(jq -r '.first_seen' "$snapshot")

  chmod 000 "$snapshot"
  run_statusline "$sandbox" vergifteter-snapshot
  chmod 644 "$snapshot"

  seen_after=$(jq -r '.first_seen' "$snapshot")
  rm -rf "$sandbox"
  if [ "$seen_after" != "$seen_before" ]; then
    printf 'FEHLER snapshots: first_seen %s wurde zu %s\n' "$seen_before" "$seen_after"
    return 1
  fi
  printf 'ok     snapshots (unlesbarer Snapshot bleibt unangetastet)\n'
}

check_stray_files_do_not_block_writes() {
  local sandbox accounts
  sandbox=$(mktemp -d)
  accounts="$sandbox/.claude/statusline-accounts"
  HOME="$sandbox" STATUSLINE_NOW="$test_now" \
    bash "$root/tests/setup/zwei-accounts.sh" "$sandbox" >/dev/null
  : > "$accounts/leer.json"
  echo 'kein json' > "$accounts/kaputt.json"

  run_statusline "$sandbox" zwei-accounts

  if [ ! -f "$accounts/$acct_a.json" ] || [ ! -f "$accounts/$acct_a.history" ]; then
    printf 'FEHLER snapshots: Streudateien blockieren Snapshot und Historie\n'
    rm -rf "$sandbox"
    return 1
  fi
  rm -rf "$sandbox"
  printf 'ok     snapshots (Streudateien blockieren nichts)\n'
}

check_first_seen_survives_unreadable_snapshot || failed=1
check_stray_files_do_not_block_writes || failed=1
exit "$failed"
