#!/usr/bin/env bash
# Gemeinsame Bausteine der Test-Setups. Wird von den Fall-Setups gesourct, damit das
# Anlegen der Accounts an genau einer Stelle steht.

ACCT_A="aaaaaaaa-0000-0000-0000-000000000001"
ACCT_B="bbbbbbbb-0000-0000-0000-000000000002"

# Schreibt den Snapshot eines Accounts, wie ihn die Statusline selbst ablegt.
# Argumente: sandbox uuid first_seen captured_at wk_used wk_reset fh_used fh_reset
write_snapshot() {
  local sandbox=$1 uuid=$2 seen=$3 captured=$4
  local wk_used=$5 wk_reset=$6 fh_used=$7 fh_reset=$8
  mkdir -p "$sandbox/.claude/statusline-accounts"
  cat > "$sandbox/.claude/statusline-accounts/${uuid}.json" <<JSON
{
  "uuid": "$uuid",
  "first_seen": $seen,
  "captured_at": $captured,
  "rate_limits": {
    "five_hour": { "used_percentage": $fh_used, "resets_at": $fh_reset },
    "seven_day": { "used_percentage": $wk_used, "resets_at": $wk_reset }
  }
}
JSON
}

# Legt das Sandbox-HOME an: aaa ist der aktive Account und steht in claude.json, bbb ist
# der zweite, dessen Stand nur als Snapshot vorliegt. aaa bekommt bewusst keinen
# Snapshot, der entsteht erst im Lauf mit first_seen = now; bbbs first_seen liegt eine
# Sekunde spaeter, damit aaa Label A behaelt.
# Argumente: sandbox now wk_used wk_reset_offset fh_used fh_reset_offset (Offsets zu now)
setup_accounts() {
  local sandbox=$1 now=$2 wk_used=$3 wk_off=$4 fh_used=$5 fh_off=$6
  mkdir -p "$sandbox/.claude/statusline-accounts"
  cat > "$sandbox/.claude.json" <<JSON
{ "oauthAccount": { "accountUuid": "$ACCT_A" } }
JSON
  write_snapshot "$sandbox" "$ACCT_B" "$((now + 1))" "$((now - 7200))" \
    "$wk_used" "$((now + wk_off))" "$fh_used" "$((now + fh_off))"
}

# Schreibt die Historie des aktiven Accounts, alle Punkte im selben Wochenfenster. Nach
# sandbox, now und dem Reset-Offset des Fensters folgen Paare aus Sekunden-Offset zu now
# (negativ ist Vergangenheit) und Prozentstand.
write_history_a() {
  local sandbox=$1 now=$2 reset=$(($2 + $3))
  shift 3
  local file="$sandbox/.claude/statusline-accounts/${ACCT_A}.history"
  : > "$file"
  while [ "$#" -ge 2 ]; do
    printf '{"t":%d,"u":%d,"r":%d}\n' "$((now + $1))" "$2" "$reset" >> "$file"
    shift 2
  done
}
