#!/usr/bin/env bash
# Claude Code – farbige Statusline
# Segmente: Verzeichnis | git-Branch | Modell | Kontext-Nutzung | ggf. Rate-Limits

# Single Source of Truth für die Version. Der Release-Workflow prüft, dass der
# gepushte Tag (v<X>) exakt hierzu passt -> kein Drift zwischen Tag und Skript.
VERSION="1.1.1"

# --version / -v / version: nur ausgeben und raus, bevor von stdin gelesen wird.
# Im Normalbetrieb ruft Claude Code das Skript ohne Argumente auf ($1 leer).
case "${1:-}" in
  --version|-v|version)
    echo "claude-code-statusline v${VERSION}"
    exit 0
    ;;
esac

# Unter Locales mit Komma als Dezimaltrenner (de_DE, fr_FR, ...) formatieren printf und
# awk "280.0k" als "280,0k" und "3.1d" als "3,1d". Einmal zentral neutralisiert, damit
# nicht jede neue Rechenstelle daran denken muss -- exportiert, weil awk als Kindprozess
# laeuft. Betrifft nur Zahlformate, nicht die Zeichenkodierung (das waere LC_CTYPE).
export LC_NUMERIC=C

# Ein Zeitpunkt fuer den ganzen Lauf. Ueber STATUSLINE_NOW stellbar, damit Tests
# Zeitpunkte setzen koennen, statt auf die Uhr zu warten. Im Normalbetrieb ist die
# Variable nicht gesetzt.
NOW="${STATUSLINE_NOW:-$(date +%s)}"

input=$(cat)

# Jarvis-Cockpit: rate_limits-Snapshot rausschreiben. Das Agent-SDK liefert die
# Auslastung nicht, nur dieser Statusline-Payload hat sie -> Jarvis liest die Datei.
mkdir -p ~/.claude 2>/dev/null
echo "$input" | jq -c '{rate_limits: (.rate_limits // {}), captured_at: now}' \
  > ~/.claude/jarvis-rate-limits.json 2>/dev/null

# --- Daten aus JSON ---
cwd=$(echo "$input"          | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input"        | jq -r '.model.display_name // ""')
total_tok=$(echo "$input"    | jq -r '.context_window.context_window_size // .context_window.total_tokens // .context_window.max_tokens // empty')
used_pct=$(echo "$input"     | jq -r '.context_window.used_percentage // empty')
# Aktuelle Tokennutzung aus current_usage summieren (präziser als percentage * size)
used_tok=$(echo "$input" | jq -r '
  (.context_window.current_usage // {}) as $u
  | (($u.input_tokens // 0)
     + ($u.output_tokens // 0)
     + ($u.cache_creation_input_tokens // 0)
     + ($u.cache_read_input_tokens // 0)) as $sum
  | if $sum > 0 then $sum else empty end')
# In jq runden (Werte kommen als Float wie 7.000000000000001) -> bash-printf sieht nie
# einen Dezimalpunkt, der im deutschen Locale als "invalid number" -> 0 enden würde.
five_h=$(echo "$input"       | jq -r '(.rate_limits.five_hour.used_percentage // empty) | round')
# Reset-Zeitstempel des 5h-Limits (Epoch) -> verbleibende Restzeit als Countdown
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
# weekly/weekly_opus tragen je nach CLI-Version unter wechselnden Keys den echten Wert
# (z.B. weekly=0 neben seven_day=7) -> Maximum der vorhandenen Werte statt blinder Vorrang.
weekly=$(echo "$input"       | jq -r '[.rate_limits.weekly.used_percentage, .rate_limits.seven_day.used_percentage] | map(select(type=="number")) | max | values | round')
weekly_opus=$(echo "$input"  | jq -r '[.rate_limits.weekly_opus.used_percentage, .rate_limits.seven_day_opus.used_percentage] | map(select(type=="number")) | max | values | round')
# Reset-Zeitstempel der Wochen-Limits (Epoch) -> verstrichene Tage fürs Daily-Pacing
weekly_reset=$(echo "$input" | jq -r '[.rate_limits.weekly.resets_at, .rate_limits.seven_day.resets_at] | map(select(type=="number")) | max | values')
vim_mode=$(echo "$input"     | jq -r '.vim.mode // empty')
# Ablaufzeitpunkt und TTL des Prompt-Caches nennt der Payload direkt. Das ersetzt die
# Rechnung ueber das Transcript, die denselben Wert nur nachbaut.
worktree=$(echo "$input"     | jq -r '.worktree.name // .workspace.git_worktree // empty')
effort=$(echo "$input"       | jq -r '.effort.level // empty')
cache_expires=$(echo "$input" | jq -r '.prompt_cache.expires_at // empty')
cache_ttl_lbl=$(echo "$input" | jq -r '.prompt_cache.ttl // empty')
transcript=$(echo "$input"   | jq -r '.transcript_path // empty')

# --- Account-Identitaet und Snapshot ---
# Der Payload nennt den Account nicht, ~/.claude.json schon. Beides zusammen ergibt
# einen Stand pro Account, aus dem sich der gerade inaktive spaeter ablesen laesst.
# Ohne Limits im Payload wird nichts geschrieben, sonst wuerde eine Sitzung vor der
# ersten API-Antwort einen echten Stand mit einem leeren ueberschreiben.
acct_dir="$HOME/.claude/statusline-accounts"
acct_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$HOME/.claude.json" 2>/dev/null)
if [ -n "$acct_uuid" ] && [ -n "${five_h}${weekly}" ]; then
  mkdir -p "$acct_dir"
  acct_file="$acct_dir/${acct_uuid}.json"
  first_seen=$(jq -r '.first_seen // empty' "$acct_file" 2>/dev/null)
  [ -n "$first_seen" ] || first_seen="$NOW"
  echo "$input" | jq -c \
    --arg uuid "$acct_uuid" --argjson now "$NOW" --argjson seen "$first_seen" \
    '{uuid: $uuid, first_seen: $seen, captured_at: $now, rate_limits: (.rate_limits // {})}' \
    > "$acct_file" 2>/dev/null
fi

# Alle bekannten Accounts, nach erstem Auftreten sortiert. Der Index im Array ist das
# Label: 0 ist A, 1 ist B, 2 ist C. Ein Fenster, dessen resets_at verstrichen ist, gilt
# als unbenutzt: Claude Code entfernt es dann aus dem Payload, und das naechste startet
# erst mit dem naechsten Prompt in diesem Account.
accounts="[]"
acct_n=0
if [ -d "$acct_dir" ]; then
  accounts=$(jq -s -c --argjson now "$NOW" '
    map(select(.uuid))
    | sort_by(.first_seen)
    | map(. + {
        wk_used:  (if (.rate_limits.seven_day.resets_at // 0) > $now
                   then (.rate_limits.seven_day.used_percentage // 0) else 0 end),
        wk_reset: (.rate_limits.seven_day.resets_at // 0),
        fh_used:  (if (.rate_limits.five_hour.resets_at // 0) > $now
                   then (.rate_limits.five_hour.used_percentage // 0) else 0 end),
        fh_reset: (.rate_limits.five_hour.resets_at // 0)
      })' "$acct_dir"/*.json 2>/dev/null) || accounts="[]"
  [ -n "$accounts" ] || accounts="[]"
  acct_n=$(echo "$accounts" | jq -r 'length')
fi

# --- Verbrauchs-Historie je Account ---
# Nur bei geaendertem Wert und hoechstens alle fuenf Minuten anhaengen, sonst waechst die
# Datei mit jedem Turn. Alles aelter als 48 Stunden faellt beim Schreiben raus.
if [ -n "$acct_uuid" ] && [ -n "$weekly" ]; then
  hist_file="$acct_dir/${acct_uuid}.history"
  last_line=$(tail -1 "$hist_file" 2>/dev/null)
  last_t=$(echo "$last_line" | jq -r '.t // 0' 2>/dev/null || echo 0)
  last_u=$(echo "$last_line" | jq -r '.u // -1' 2>/dev/null || echo -1)
  if [ "$weekly" != "$last_u" ] && [ $((NOW - last_t)) -ge 300 ]; then
    printf '{"t":%d,"u":%d}\n' "$NOW" "$weekly" >> "$hist_file"
    tmp_hist="${hist_file}.tmp"
    if jq -c --argjson cut "$((NOW - 172800))" 'select(.t >= $cut)' "$hist_file" > "$tmp_hist" 2>/dev/null; then
      mv "$tmp_hist" "$hist_file"
    else
      rm -f "$tmp_hist"
    fi
  fi
fi

# --- Verbrauchstempo der letzten 24 Stunden ueber alle Accounts ---
# Je Account getrennt rechnen und erst dann summieren. Zusammengeworfen wuerden die
# Zeitreihen zweier Accounts ineinandersortiert, und jeder Wechsel erschiene als
# gewaltiger Sprung. Faellt der Wert innerhalb eines Accounts, hat sein Fenster
# zurueckgesetzt: dann zaehlt der neue Stand selbst als Verbrauch, nicht die negative
# Differenz. Unter zwei Messpunkten bleibt das Tempo unbekannt statt null, sonst
# behauptete eine frische Installation, es werde nichts verbraucht.
burn_24h=""
burn_sum=0
burn_known=0
for hist_f in "$acct_dir"/*.history; do
  [ -f "$hist_f" ] || continue
  hist_d=$(jq -s -r --argjson from "$((NOW - 86400))" '
    map(select(.t >= $from)) | sort_by(.t)
    | if length < 2 then "?"
      else . as $r
        | ([range(1; ($r | length))
            | ($r[.].u - $r[. - 1].u) as $step
            | if $step >= 0 then $step else $r[.].u end] | add | tostring)
      end' "$hist_f" 2>/dev/null) || hist_d="?"
  [ "$hist_d" = "?" ] && continue
  burn_sum=$(awk -v a="$burn_sum" -v b="$hist_d" 'BEGIN{printf "%.2f", a + b}')
  burn_known=1
done
[ "$burn_known" = 1 ] && burn_24h="$burn_sum"

# Fallback: falls current_usage leer, aus Prozent + Gesamtgröße berechnen
if [ -z "$used_tok" ] && [ -n "$used_pct" ] && [ -n "$total_tok" ]; then
  used_tok=$(awk -v p="$used_pct" -v t="$total_tok" 'BEGIN{printf "%d", p/100*t}')
fi

# --- git-Branch (ohne optionale Locks) ---
branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
         || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)

# --- ANSI-Farben ---
RESET='\033[0m'
BOLD='\033[1m'
C_DIR='\033[96m'        # helles Cyan  – Verzeichnis
C_GIT='\033[92m'        # helles Grün  – git-Branch
C_MODEL='\033[95m'      # helles Magenta – Modell
C_CTX='\033[93m'        # Gelb         – Kontext
C_CTX_OK='\033[92m'     # Grün         – Kontext niedrig
C_WARN='\033[91m'       # helles Rot   – Warnung
C_SEP='\033[2;37m'      # Dim-Weiß     – Trennzeichen
C_CACHE='\033[36m'      # Cyan          – Prompt-Cache TTL
C_ORANGE='\033[38;5;208m' # Orange       – ctxQ im mittleren Bereich

SEP=" ${C_SEP}|${RESET} "

# NO_COLOR (https://no-color.org) leert alle Sequenzen. Die Tests vergleichen so reinen
# Text, statt ANSI-Codes mitzupflegen.
if [ -n "${NO_COLOR:-}" ]; then
  RESET='' BOLD='' C_DIR='' C_GIT='' C_MODEL='' C_CTX='' C_CTX_OK='' \
    C_WARN='' C_SEP='' C_CACHE='' C_ORANGE=''
  SEP=" | "
fi

# --- Hilfsfunktion: Tokens hübsch formatieren (z.B. 48400 -> 48.4k, 1000000 -> 1M) ---
fmt_tok() {
  local n=$1
  if [ -z "$n" ] || [ "$n" = "null" ]; then
    echo ""
    return
  fi
  awk -v n="$n" 'BEGIN{
    if (n >= 1000000)      printf "%.1fM", n/1000000
    else if (n >= 1000)    printf "%.1fk", n/1000
    else                   printf "%d", n
  }' | sed 's/\.0\([kM]\)/\1/'
}

# --- Segment 1: Verzeichnis (Home als ~) ---
home="${HOME:-/Users/chris}"
short_cwd="${cwd/#$home/~}"
seg_dir="${C_DIR}${BOLD}${short_cwd}${RESET}"

# --- Segment 2: git-Branch ---
if [ -n "$branch" ]; then
  seg_git="${C_GIT} ${branch}${RESET}"
else
  seg_git=""
fi

# --- Segment 2b: Worktree ---
# Nur gesetzt, wenn die Sitzung in einem Worktree laeuft. Im Hauptbaum fehlt das Feld.
seg_worktree=""
if [ -n "$worktree" ]; then
  seg_worktree="${C_GIT}wt ${worktree}${RESET}"
fi

# --- Segment 3: Modell ---
seg_model="${C_MODEL}${model}${RESET}"

# --- Segment 3b: Effort-Stufe ---
# Der Payload nennt den Wert der laufenden Sitzung, also auch den nach einem /effort.
seg_effort=""
if [ -n "$effort" ]; then
  seg_effort="${C_MODEL}effort ${effort}${RESET}"
fi

# --- Hilfsfunktion: Progressbar (10 Segmente) ---
# Args: percent (0-100)  -> "█████░░░░░"
make_bar() {
  local p=$1
  local width=10
  local filled
  filled=$(awk -v p="$p" -v w="$width" 'BEGIN{
    f = int(p/100*w + 0.5)
    if (f < 0) f = 0
    if (f > w) f = w
    printf "%d", f
  }')
  local empty=$((width - filled))
  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar="${bar}█"; done
  for ((i=0; i<empty;  i++)); do bar="${bar}░"; done
  printf "%s" "$bar"
}

# --- Label eines Accounts (A, B, C ...) aus der Sortierung nach erstem Auftreten ---
# Bei nur einem bekannten Account bleibt das Label leer, dann sieht die Zeile aus wie
# vor dem Umbau.
acct_label() {
  local uuid=$1
  [ "$acct_n" -ge 2 ] || return 0
  echo "$accounts" | jq -r --arg u "$uuid" '
    (map(.uuid) | index($u)) as $i
    | if $i == null then "" else (("ABCDEFGH" | split(""))[$i]) end'
}

# --- Farbauswahl nach Prozent ---
# Args: percent [warn_at] [caution_at] -- Schwellen überschreibbar, weil nicht jedes
# Budget gleich frueh alarmiert: beim Wochenlimit ist 80% noch normaler Verbrauch.
pct_color() {
  local p=$1
  local warn_at=${2:-80}
  local caution_at=${3:-50}
  if [ "$p" -ge "$warn_at" ]; then
    printf "%b" "$C_WARN"
  elif [ "$p" -ge "$caution_at" ]; then
    printf "%b" "$C_CTX"
  else
    printf "%b" "$C_CTX_OK"
  fi
}

# --- Segment 4: Kontext (Progressbar + Tokens + Prozent) ---
seg_ctx=""
if [ -n "$used_tok" ]; then
  used_fmt=$(fmt_tok "$used_tok")
  total_fmt=$(fmt_tok "$total_tok")
  pct="${used_pct:-0}"
  pct_int=$(printf '%.0f' "$pct" 2>/dev/null || echo 0)
  col=$(pct_color "$pct_int")
  bar=$(make_bar "$pct_int")
  if [ -n "$total_fmt" ]; then
    seg_ctx="${col}ctx ${bar} ${pct_int}% (${used_fmt}/${total_fmt})${RESET}"
  else
    seg_ctx="${col}ctx ${bar} ${pct_int}% (${used_fmt})${RESET}"
  fi
fi

# --- Segment 5: 5h-Rate-Limit (immer wenn vorhanden) ---
seg_rate=""
if [ -n "$five_h" ]; then
  rate_val=$(printf '%.0f' "$five_h")
  col=$(pct_color "$rate_val")
  # Restzeit bis Reset in Klammern: "1h58m" bzw. "<1h -> 42m"
  cd=""
  if [ -n "$five_h_reset" ]; then
    cd=$(awk -v reset="$five_h_reset" -v now="$NOW" 'BEGIN{
      s = reset - now
      if (s < 0) s = 0
      h = int(s / 3600)
      m = int((s % 3600) / 60)
      if (h > 0) printf " (%dh%02dm)", h, m
      else       printf " (%dm)", m
    }')
  fi
  seg_rate="${col}5h ${rate_val}%${cd}${RESET}"
  # Ab zwei Accounts bekommt der aktive seinen Buchstaben, die uebrigen haengen dahinter:
  # "frei", wenn ihr 5h-Fenster durch ist, sonst ihr letzter bekannter Stand.
  if [ "$acct_n" -ge 2 ]; then
    lbl=$(acct_label "$acct_uuid")
    seg_rate="${col}5h ${lbl} ${rate_val}%${cd}${RESET}"
    others=$(echo "$accounts" | jq -r --arg u "$acct_uuid" --argjson now "$NOW" '
      to_entries[] | select(.value.uuid != $u)
      | (("ABCDEFGH" | split(""))[.key]) as $lbl
      | if .value.fh_reset <= $now then "\($lbl) frei" else "\($lbl) \(.value.fh_used)%" end' \
      | tr '\n' ' ')
    others="${others% }"
    [ -n "$others" ] && seg_rate="${seg_rate} ${C_SEP}${others}${RESET}"
  fi
fi

# --- Segment 5a: Daily-Pacing-Delta (zwischen 5h und wk) ---
# Die Woche ist das 100%-Budget (wk). Bei gleichmäßigem Verbrauch "darf" man pro
# verstrichenem Tag 1/7 (~14,29%) ausgeben. delta = Soll(Zeit) - Ist(wk):
#   delta > 0  -> unter Budget, "im Plus"  (grün)
#   delta < 0  -> über Budget, zu schnell verbrannt, "im Minus" (gelb/rot)
seg_daily=""
if [ -n "$weekly" ] && [ -n "$weekly_reset" ]; then
  daily_calc=$(awk -v reset="$weekly_reset" -v used="$weekly" -v now="$NOW" 'BEGIN{
    days_left = (reset - now) / 86400
    if (days_left < 0) days_left = 0
    if (days_left > 7) days_left = 7
    days_elapsed = 7 - days_left
    expected = days_elapsed / 7 * 100          # Soll-Verbrauch nach verstrichener Zeit
    delta = expected - used                    # >0 = Plus (unter Budget)
    delta = (delta < 0) ? -int(-delta + 0.5) : int(delta + 0.5)  # runden, kein "-0"
    printf "%d %.1f", delta, days_left
  }')
  read -r d_val d_days_left <<< "$daily_calc"
  # Farbe nach Pacing: Plus grün, Minus < 1 Tag gelb, Minus >= 1 Tag (14%) rot
  if   [ "$d_val" -ge 0 ];   then dcol="$C_CTX_OK"
  elif [ "$d_val" -gt -14 ]; then dcol="$C_CTX"
  else                            dcol="$C_WARN"
  fi
  sign=""; [ "$d_val" -ge 0 ] && sign="+"   # Vorzeichen explizit -> als Delta lesbar
  seg_daily="${dcol}d ${sign}${d_val}% (${d_days_left}d)${RESET}"
fi

# --- Segment 5a2: Runway ueber das Gesamtbudget (ersetzt das Delta ab zwei Accounts) ---
# Das Budget fuellt sich mit N mal 100 Punkten pro sieben Tage nach. Liegt das Tempo
# darunter, laeuft nichts leer. Darueber bleiben Rest / (Tempo - Nachfuellrate) Tage. Die
# Rechnung glaettet die einzelnen Resets zu einem gleichmaessigen Zufluss und liegt
# deshalb um Stunden daneben, wenn ein Reset unmittelbar bevorsteht.
if [ "$acct_n" -ge 2 ]; then
  if [ -z "$burn_24h" ]; then
    seg_daily="${C_SEP}rw ?${RESET}"
  else
    rest=$(echo "$accounts" | jq -r 'map(100 - .wk_used) | add')
    seg_daily=$(awk -v rest="$rest" -v rate="$burn_24h" -v n="$acct_n" \
      -v ok="$C_CTX_OK" -v mid="$C_CTX" -v warn="$C_WARN" -v rst="$RESET" 'BEGIN{
      refill = n * 100 / 7
      if (rate <= refill) { printf "%srw oo%s", ok, rst; exit }
      days = rest / (rate - refill)
      col = (days < 1) ? warn : ((days < 3) ? mid : ok)
      printf "%srw %.1fd%s", col, days, rst
    }')
  fi
fi

# --- Segment 5a3: Wechselsignal ---
# Zwei Gruende, den Account zu wechseln. Erstens Erschoepfung: hier ist Schluss, woanders
# nicht. Zweitens Verfall: dort laeuft mehr Budget pro Tag ab als hier, es geht also
# verloren, wenn es liegen bleibt. Beides zaehlt nur, wenn im Ziel ueberhaupt
# 5h-Kapazitaet frei ist, sonst bringt der Wechsel nichts.
# Der Verfallsgrund allein wuerde den haeufigsten Fall verpassen: ein frisch
# zurueckgesetzter Account hat sieben Tage fuer 100 Punkte und damit fast immer die
# niedrigere Verfallsrate, obwohl genau dorthin zu wechseln waere.
seg_switch=""
if [ "$acct_n" -ge 2 ] && [ -n "$acct_uuid" ]; then
  switch_to=$(echo "$accounts" | jq -r --arg u "$acct_uuid" --argjson now "$NOW" '
    ((map(select(.uuid == $u)) | first) // {}) as $me
    | (if ($me.wk_reset // 0) > $now then ($me.wk_reset - $now) / 86400 else 7 end) as $me_days
    | ((100 - ($me.wk_used // 0)) / $me_days) as $me_decay
    | ((($me.fh_used // 0) >= 95) or (($me.wk_used // 0) >= 95)) as $me_done
    | [ to_entries[]
        | select(.value.uuid != $u)
        | (("ABCDEFGH" | split(""))[.key]) as $lbl
        | (if .value.fh_reset <= $now then 0 else .value.fh_used end) as $fh
        | select($fh < 95)
        | (if .value.wk_reset > $now then (.value.wk_reset - $now) / 86400 else 7 end) as $days
        | ((100 - .value.wk_used) / $days) as $decay
        | select($me_done or ($decay > $me_decay))
        | {lbl: $lbl, decay: $decay}
      ]
    | sort_by(-.decay) | first | .lbl // empty')
  if [ -n "$switch_to" ]; then
    seg_switch="${C_WARN}-> ${switch_to}${RESET}"
  fi
fi

# --- Segment 5b: Weekly-Rate-Limit (immer wenn vorhanden) ---
seg_weekly=""
if [ -n "$weekly" ]; then
  w_val=$(printf '%.0f' "$weekly")
  col=$(pct_color "$w_val" 90)
  seg_weekly="${col}wk ${w_val}%${RESET}"
  # Ab zwei Accounts steht hinter jedem Wert die Restlaufzeit seines Fensters. Damit
  # laesst sich das Wechselsignal nachrechnen, statt ihm glauben zu muessen. Ein Fenster,
  # dessen resets_at verstrichen ist, bekommt volle sieben Tage: es startet erst mit dem
  # naechsten Prompt in diesem Account.
  if [ "$acct_n" -ge 2 ]; then
    wk_all=$(echo "$accounts" | jq -r --argjson now "$NOW" '
      to_entries[]
      | (("ABCDEFGH" | split(""))[.key]) as $lbl
      | (if .value.wk_reset > $now then (.value.wk_reset - $now) / 86400 else 7 end) as $days
      | "\($lbl) \(.value.wk_used)% (\(($days * 10 | round) / 10)d)"' | tr '\n' ' ')
    seg_weekly="${col}wk ${wk_all% }${RESET}"
  fi
fi

# --- Segment 5c: Weekly-Opus-Rate-Limit (falls vorhanden) ---
seg_weekly_opus=""
if [ -n "$weekly_opus" ]; then
  wo_val=$(printf '%.0f' "$weekly_opus")
  col=$(pct_color "$wo_val")
  seg_weekly_opus="${col}wk-opus ${wo_val}%${RESET}"
fi

# --- Segment ContextQ (token-optimizer Quality-Score, pro Session) ---
# Der UserPromptSubmit-Hook des token-optimizer-Plugins schreibt alle ~2 Min einen
# Score nach ~/.claude/token-optimizer/quality-cache-<sessionUUID>.json. Die UUID ist
# der Basename des transcript_path. Fallback auf den globalen Cache.
# Die Session-Datei entsteht erst nach den ersten Minuten Laufzeit, und den globalen
# Fallback legt der Hook gar nicht erst an -> eine frische Session hat schlicht noch
# keinen Score. Dann Platzhalter statt Leerstelle, sonst liest sich das fehlende
# Segment wie ein Defekt.
seg_ctxq=""
if [ -n "$transcript" ]; then
  seg_ctxq="${C_SEP}ctxQ …${RESET}"
  sid=$(basename "$transcript" .jsonl)
  qfile="$HOME/.claude/token-optimizer/quality-cache-${sid}.json"
  [ -f "$qfile" ] || qfile="$HOME/.claude/token-optimizer/quality-cache.json"
  if [ -f "$qfile" ]; then
    qdata=$(jq -r '[((.resource_health // .score) | round), (.resource_health_grade // .grade // "?")] | @tsv' "$qfile" 2>/dev/null)
    IFS=$'\t' read -r q_score q_grade <<< "$qdata"
    if [ -n "$q_score" ] && [ "$q_score" != "null" ]; then
      if   [ "$q_score" -ge 85 ]; then qcol="$C_CTX_OK"
      elif [ "$q_score" -ge 75 ]; then qcol="$C_CTX"
      elif [ "$q_score" -ge 50 ]; then qcol="$C_ORANGE"
      else                             qcol="$C_WARN"
      fi
      seg_ctxq="${qcol}ctxQ ${q_grade}(${q_score})${RESET}"
    fi
  fi
fi

# --- Segment Prompt-Cache TTL + Countdown ---
# Erste Wahl ist prompt_cache aus dem Payload: dort stehen die ausgehandelte TTL und der
# Ablaufzeitpunkt fertig drin. Fehlt das Feld (aeltere Claude-Code-Version), rechnet der
# Zweig darunter denselben Wert aus dem Transcript nach.
# TTL: 1h wenn ENABLE_PROMPT_CACHING_1H gesetzt, sonst 5m. Der Cache wird bei JEDEM
# API-Call neu geschrieben und die TTL dabei auf voll zurueckgesetzt -- also nicht nur
# bei einer Eingabe, sondern bei jedem Turn-Step waehrend der Agent arbeitet. Der
# korrekte Referenzpunkt ("wann wurde der Cache zuletzt geschrieben") ist daher der
# Timestamp der letzten assistant-Message: die 1h startet erst, wenn der Agent DURCH
# ist. Der Transcript-mtime taugt nicht (Hooks/Memory-Consolidation beruehren ihn ohne
# Cache-Touch). Restzeit = TTL - (jetzt - letzter_turn). Ruht die Session, laeuft sie
# ab und bleibt auf "cold" -- das Signal, dass der Cache weg ist (handoff/clear faellig).
case "${ENABLE_PROMPT_CACHING_1H:-}" in
  1|true|TRUE) cache_ttl=3600; cache_label="1h" ;;
  *)           cache_ttl=300;  cache_label="5m" ;;
esac
# Sagt der Payload etwas anderes, gilt der Payload: er kennt die tatsaechlich
# ausgehandelte TTL, die Umgebungsvariable nur den Wunsch.
case "$cache_ttl_lbl" in
  1h) cache_ttl=3600; cache_label="1h" ;;
  5m) cache_ttl=300;  cache_label="5m" ;;
esac
seg_cache="${C_CACHE}cache ${cache_label}${RESET}"
cache_calc=""
if [ -n "$cache_expires" ]; then
  cache_calc=$(awk -v expires="$cache_expires" -v now="$NOW" 'BEGIN{
    s = expires - now
    if (s < 0) s = 0
    h = int(s/3600); m = int((s%3600)/60); sec = int(s%60)
    if      (s <= 0) lbl = "cold"
    else if (h > 0)  lbl = sprintf("%dh%02dm", h, m)
    else if (m > 0)  lbl = sprintf("%dm%02ds", m, sec)
    else             lbl = sprintf("%ds", sec)
    printf "%d|%s", s, lbl
  }')
elif [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # Epoch des letzten Cache-Touch = spaetester Timestamp aus assistant-Message (jeder
  # API-Call schreibt Cache) und echter User-Eingabe (type=user, kein isMeta, content
  # String oder Array ohne tool_result -- deckt den Latenz-Fall ab, waehrend der Agent
  # auf die neue Eingabe noch nicht geantwortet hat). Meta/Hook-Zeilen fallen raus.
  t_mtime=$(jq -r 'select((.type=="assistant") or (.type=="user" and (.isMeta|not) and ((.message.content|type=="string") or ((.message.content|type=="array") and (any(.message.content[]; .type=="tool_result")|not))))) | (.timestamp | sub("\\.[0-9]+";"") | fromdateiso8601)' "$transcript" 2>/dev/null | tail -1)
  # Fallback auf File-mtime, falls das Transcript (noch) keine parsebare Turn-Zeile hat.
  [ -n "$t_mtime" ] || t_mtime=$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo 0)
  cache_calc=$(awk -v ttl="$cache_ttl" -v mt="$t_mtime" -v now="$NOW" 'BEGIN{
    if (mt <= 0) { print "-1|"; exit }
    s = ttl - (now - mt)
    if (s < 0) s = 0
    h = int(s/3600); m = int((s%3600)/60); sec = int(s%60)
    if      (s <= 0) lbl = "cold"
    else if (h > 0)  lbl = sprintf("%dh%02dm", h, m)
    else if (m > 0)  lbl = sprintf("%dm%02ds", m, sec)
    else             lbl = sprintf("%ds", sec)
    printf "%d|%s", s, lbl
  }')
fi

# Farbe: viel Zeit Cyan, letztes Fuenftel Gelb, abgelaufen Rot. Gilt fuer beide Wege.
if [ -n "$cache_calc" ]; then
  c_secs="${cache_calc%%|*}"; c_lbl="${cache_calc##*|}"
  if [ "$c_secs" != "-1" ]; then
    thresh=$(awk -v t="$cache_ttl" 'BEGIN{printf "%d", t*0.2}')
    if   [ "$c_secs" -le 0 ];         then ccol="$C_WARN"
    elif [ "$c_secs" -lt "$thresh" ]; then ccol="$C_CTX"
    else                                   ccol="$C_CACHE"
    fi
    seg_cache="${ccol}cache ${c_lbl}/${cache_label}${RESET}"
  fi
fi

# --- Segment 6: Vim-Mode ---
seg_vim=""
if [ -n "$vim_mode" ]; then
  seg_vim="${C_CTX}[${vim_mode}]${RESET}"
fi

# --- Segmente zu einer Zeile fügen (leere überspringen, kein führender Trenner) ---
join_segs() {
  local out="" seg
  for seg in "$@"; do
    [ -n "$seg" ] || continue
    [ -z "$out" ] && out="$seg" || out="${out}${SEP}${seg}"
  done
  printf '%s' "$out"
}

# --- Statusline zusammensetzen (4-zeilig) ---
# Zeile 1 (Ort):      Pfad, branch, worktree
# Zeile 2 (Werkzeug): Modell, Effort, vim
# Zeile 3 (Sitzung):  ctxQ, ctx, cache
# Zeile 4 (Limits):   5h, wk, (wk-opus), d bzw. Runway, (Wechselsignal)
# Eine leere Zeile entfaellt ganz, statt als Leerzeile zu erscheinen: eine Sitzung ohne
# Rate-Limits hat damit drei Zeilen statt einer Luecke.
line1=$(join_segs "$seg_dir" "$seg_git" "$seg_worktree")
line2=$(join_segs "$seg_model" "$seg_effort" "$seg_vim")
line3=$(join_segs "$seg_ctxq" "$seg_ctx" "$seg_cache")
line4=$(join_segs "$seg_rate" "$seg_weekly" "$seg_weekly_opus" "$seg_daily" "$seg_switch")

out="$line1"
for line in "$line2" "$line3" "$line4"; do
  [ -n "$line" ] && out="${out}"$'\n'"${line}"
done
printf "%b" "$out"
