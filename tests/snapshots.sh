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
acct_b="bbbbbbbb-0000-0000-0000-000000000002"
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

# Die Mail kommt aus ~/.claude.json und gehoert dem Login. Beide Snapshots tragen nach
# einem Lauf ihre eigene: A die aus claude.json, B die aus seinem alten Snapshot.
check_mail_follows_login() {
  local sandbox accounts mail_a mail_b
  sandbox=$(mktemp -d)
  accounts="$sandbox/.claude/statusline-accounts"
  HOME="$sandbox" STATUSLINE_NOW="$test_now" \
    bash "$root/tests/setup/link-handler-ziel.sh" "$sandbox" >/dev/null
  run_statusline "$sandbox" zwei-accounts
  mail_a=$(jq -r '.email // ""' "$accounts/$acct_a.json")
  mail_b=$(jq -r '.email // ""' "$accounts/$acct_b.json")
  rm -rf "$sandbox"
  if [ "$mail_a" != a@example.com ] || [ "$mail_b" != b@example.com ]; then
    printf 'FEHLER snapshots: Mails A=%s B=%s, erwartet a@example.com und b@example.com\n' \
      "$mail_a" "$mail_b"
    return 1
  fi
  printf 'ok     snapshots (Mail landet beim Login)\n'
}

# Eingeloggt ist A, der Payload gehoert noch B (wie fremder-payload). Bs Snapshot wird
# in diesem Lauf geschrieben. Er darf nicht As Mail bekommen und muss seine eigene
# behalten: sonst wechselte der Klick auf "-> B" zu A, oder er fiele nach jedem
# Kontowechsel still auf die Rotation zurueck.
# Die Variable heisst bewusst nicht sandbox: lib.sh nutzt "local sandbox", im
# Subshell-Source meldet shellcheck sonst SC2031.
check_mail_not_given_to_foreign_owner() {
  local home accounts mail_b captured_b
  home=$(mktemp -d)
  accounts="$home/.claude/statusline-accounts"
  (
    # shellcheck source=tests/setup/lib.sh
    . "$root/tests/setup/lib.sh"
    setup_accounts "$home" "$test_now" 5 501120 1 7200 a@example.com b@example.com
    write_snapshot "$home" "$ACCT_A" "$((test_now - 100))" "$((test_now - 600))" \
      43 "$((test_now + 293760))" 10 "$((test_now + 3600))" a@example.com
  )
  run_statusline "$home" fremder-payload
  mail_b=$(jq -r '.email // ""' "$accounts/$acct_b.json")
  captured_b=$(jq -r '.captured_at' "$accounts/$acct_b.json")
  rm -rf "$home"
  if [ "$captured_b" != "$test_now" ]; then
    printf 'FEHLER snapshots: Bs Snapshot wurde nicht geschrieben, der Fall prueft nichts\n'
    return 1
  fi
  if [ "$mail_b" != b@example.com ]; then
    printf 'FEHLER snapshots: B hat die Mail %s, erwartet seine eigene b@example.com\n' "$mail_b"
    return 1
  fi
  printf 'ok     snapshots (fremder Besitzer behaelt seine Mail)\n'
}

check_first_seen_survives_unreadable_snapshot || failed=1
check_stray_files_do_not_block_writes || failed=1
check_mail_follows_login || failed=1
check_mail_not_given_to_foreign_owner || failed=1
exit "$failed"
