#!/usr/bin/env bash
# Claude Code – farbige Statusline
# Segmente: Verzeichnis | git-Branch | Modell | Kontext-Nutzung | ggf. Rate-Limits

# Single Source of Truth für die Version. Der Release-Workflow prüft, dass der
# gepushte Tag (v<X>) exakt hierzu passt -> kein Drift zwischen Tag und Skript.
VERSION="1.1.0"

# --version / -v / version: nur ausgeben und raus, bevor von stdin gelesen wird.
# Im Normalbetrieb ruft Claude Code das Skript ohne Argumente auf ($1 leer).
case "${1:-}" in
  --version|-v|version)
    echo "claude-code-statusline v${VERSION}"
    exit 0
    ;;
esac

input=$(cat)

# Jarvis-Cockpit: rate_limits-Snapshot rausschreiben. Das Agent-SDK liefert die
# Auslastung nicht, nur dieser Statusline-Payload hat sie -> Jarvis liest die Datei.
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
transcript=$(echo "$input"   | jq -r '.transcript_path // empty')

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

SEP=" ${C_SEP}|${RESET} "

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

# --- Segment 3: Modell ---
seg_model="${C_MODEL}${model}${RESET}"

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

# --- Farbauswahl nach Prozent ---
pct_color() {
  local p=$1
  if [ "$p" -ge 80 ]; then
    printf "%b" "$C_WARN"
  elif [ "$p" -ge 50 ]; then
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
  pct_int=$(LC_NUMERIC=C printf '%.0f' "$pct" 2>/dev/null || echo 0)
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
  rate_val=$(LC_NUMERIC=C printf '%.0f' "$five_h")
  col=$(pct_color "$rate_val")
  # Restzeit bis Reset in Klammern: "1h58m" bzw. "<1h -> 42m"
  cd=""
  if [ -n "$five_h_reset" ]; then
    cd=$(awk -v reset="$five_h_reset" -v now="$(date +%s)" 'BEGIN{
      s = reset - now
      if (s < 0) s = 0
      h = int(s / 3600)
      m = int((s % 3600) / 60)
      if (h > 0) printf " (%dh%02dm)", h, m
      else       printf " (%dm)", m
    }')
  fi
  seg_rate="${col}5h ${rate_val}%${cd}${RESET}"
fi

# --- Segment 5a: Daily-Pacing-Delta (zwischen 5h und wk) ---
# Die Woche ist das 100%-Budget (wk). Bei gleichmäßigem Verbrauch "darf" man pro
# verstrichenem Tag 1/7 (~14,29%) ausgeben. delta = Soll(Zeit) - Ist(wk):
#   delta > 0  -> unter Budget, "im Plus"  (grün)
#   delta < 0  -> über Budget, zu schnell verbrannt, "im Minus" (gelb/rot)
seg_daily=""
if [ -n "$weekly" ] && [ -n "$weekly_reset" ]; then
  daily_calc=$(awk -v reset="$weekly_reset" -v used="$weekly" -v now="$(date +%s)" 'BEGIN{
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

# --- Segment 5b: Weekly-Rate-Limit (immer wenn vorhanden) ---
seg_weekly=""
if [ -n "$weekly" ]; then
  w_val=$(LC_NUMERIC=C printf '%.0f' "$weekly")
  col=$(pct_color "$w_val")
  seg_weekly="${col}wk ${w_val}%${RESET}"
fi

# --- Segment 5c: Weekly-Opus-Rate-Limit (falls vorhanden) ---
seg_weekly_opus=""
if [ -n "$weekly_opus" ]; then
  wo_val=$(LC_NUMERIC=C printf '%.0f' "$weekly_opus")
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
      elif [ "$q_score" -ge 50 ]; then qcol='\033[38;5;208m'
      else                             qcol="$C_WARN"
      fi
      seg_ctxq="${qcol}ctxQ ${q_grade}(${q_score})${RESET}"
    fi
  fi
fi

# --- Segment Prompt-Cache TTL + Countdown ---
# TTL: 1h wenn ENABLE_PROMPT_CACHING_1H gesetzt, sonst 5m. Der Cache wird bei JEDEM
# API-Call neu geschrieben und die TTL dabei auf voll zurueckgesetzt -- also nicht nur
# bei einer Eingabe, sondern bei jedem Turn-Step waehrend der Agent arbeitet. Der
# korrekte Referenzpunkt ("wann wurde der Cache zuletzt geschrieben") ist daher der
# Timestamp der letzten assistant-Message: die 1h startet erst, wenn der Agent DURCH
# ist. Der Transcript-mtime taugt nicht (Hooks/Memory-Consolidation beruehren ihn ohne
# Cache-Touch). Restzeit = TTL - (jetzt - letzter_turn). Ruht die Session, laeuft sie
# ab und bleibt auf "kalt" -- das Signal, dass der Cache weg ist (handoff/clear faellig).
case "${ENABLE_PROMPT_CACHING_1H:-}" in
  1|true|TRUE) cache_ttl=3600; cache_label="1h" ;;
  *)           cache_ttl=300;  cache_label="5m" ;;
esac
seg_cache="${C_CACHE}cache ${cache_label}${RESET}"
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # Epoch des letzten Cache-Touch = spaetester Timestamp aus assistant-Message (jeder
  # API-Call schreibt Cache) und echter User-Eingabe (type=user, kein isMeta, content
  # String oder Array ohne tool_result -- deckt den Latenz-Fall ab, waehrend der Agent
  # auf die neue Eingabe noch nicht geantwortet hat). Meta/Hook-Zeilen fallen raus.
  t_mtime=$(jq -r 'select((.type=="assistant") or (.type=="user" and (.isMeta|not) and ((.message.content|type=="string") or ((.message.content|type=="array") and (any(.message.content[]; .type=="tool_result")|not))))) | (.timestamp | sub("\\.[0-9]+";"") | fromdateiso8601)' "$transcript" 2>/dev/null | tail -1)
  # Fallback auf File-mtime, falls das Transcript (noch) keine parsebare Turn-Zeile hat.
  [ -n "$t_mtime" ] || t_mtime=$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo 0)
  cache_calc=$(awk -v ttl="$cache_ttl" -v mt="$t_mtime" -v now="$(date +%s)" 'BEGIN{
    if (mt <= 0) { print "-1|"; exit }
    s = ttl - (now - mt)
    if (s < 0) s = 0
    h = int(s/3600); m = int((s%3600)/60); sec = int(s%60)
    if      (s <= 0) lbl = "kalt"
    else if (h > 0)  lbl = sprintf("%dh%02dm", h, m)
    else if (m > 0)  lbl = sprintf("%dm%02ds", m, sec)
    else             lbl = sprintf("%ds", sec)
    printf "%d|%s", s, lbl
  }')
  c_secs="${cache_calc%%|*}"; c_lbl="${cache_calc##*|}"
  if [ "$c_secs" != "-1" ]; then
    # Farbe: viel Zeit Cyan, letztes Fünftel Gelb, abgelaufen Rot.
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

# --- Statusline zusammensetzen (2-zeilig) ---
# Zeile 1 (Umfeld):   Pfad, branch, model, cache-countdown, (vim)
# Zeile 2 (Metriken): ctxQ, 5h, d, wk, (wk-opus), ctx
line1=$(join_segs "$seg_dir" "$seg_git" "$seg_model" "$seg_cache" "$seg_vim")
line2=$(join_segs "$seg_ctxq" "$seg_rate" "$seg_daily" "$seg_weekly" "$seg_weekly_opus" "$seg_ctx")

if [ -n "$line2" ]; then
  printf "%b\n%b" "$line1" "$line2"
else
  printf "%b" "$line1"
fi
