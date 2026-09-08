#!/usr/bin/env bash
# Gemeinsame Bausteine der Test-Setups. Wird von den Fall-Setups gesourct, damit das
# Anlegen der Accounts an genau einer Stelle steht.

ACCT_A="aaaaaaaa-0000-0000-0000-000000000001"
ACCT_B="bbbbbbbb-0000-0000-0000-000000000002"

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
  cat > "$sandbox/.claude/statusline-accounts/${ACCT_B}.json" <<JSON
{
  "uuid": "$ACCT_B",
  "first_seen": $((now + 1)),
  "captured_at": $((now - 7200)),
  "rate_limits": {
    "five_hour": { "used_percentage": $fh_used, "resets_at": $((now + fh_off)) },
    "seven_day": { "used_percentage": $wk_used, "resets_at": $((now + wk_off)) }
  }
}
JSON
}

# Schreibt die Historie des aktiven Accounts. Nach sandbox und now folgen Paare aus
# Sekunden-Offset zu now (negativ ist Vergangenheit) und Prozentstand.
write_history_a() {
  local sandbox=$1 now=$2
  shift 2
  local file="$sandbox/.claude/statusline-accounts/${ACCT_A}.history"
  : > "$file"
  while [ "$#" -ge 2 ]; do
    printf '{"t":%d,"u":%d}\n' "$((now + $1))" "$2" >> "$file"
    shift 2
  done
}
