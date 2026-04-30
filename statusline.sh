#!/usr/bin/env bash
# Claude Code – farbige Statusline
# Segmente: Verzeichnis | git-Branch | Modell | Kontext-Nutzung | ggf. Rate-Limits

input=$(cat)

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
five_h=$(echo "$input"       | jq -r '.rate_limits.five_hour.used_percentage // empty')
weekly=$(echo "$input"       | jq -r '.rate_limits.weekly.used_percentage // .rate_limits.seven_day.used_percentage // empty')
weekly_opus=$(echo "$input"  | jq -r '.rate_limits.weekly_opus.used_percentage // empty')
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
C_AGT='\033[94m'        # helles Blau   – Sub-Agents
C_SKL='\033[35m'        # Magenta       – Skills

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
  seg_rate="${col}5h ${rate_val}%${RESET}"
fi

# --- Segment 5b: Weekly-Rate-Limit (immer wenn vorhanden) ---
seg_weekly=""
if [ -n "$weekly" ]; then
  w_val=$(printf '%.0f' "$weekly")
  col=$(pct_color "$w_val")
  seg_weekly="${col}wk ${w_val}%${RESET}"
fi

# --- Segment 5c: Weekly-Opus-Rate-Limit (falls vorhanden) ---
seg_weekly_opus=""
if [ -n "$weekly_opus" ]; then
  wo_val=$(printf '%.0f' "$weekly_opus")
  col=$(pct_color "$wo_val")
  seg_weekly_opus="${col}wk-opus ${wo_val}%${RESET}"
fi

# --- Segment Agents/Skills (used / available) ---
# Used: Task- bzw. Skill-Aufrufe aus dem aktuellen Transcript.
# Available: alle installierten Sub-Agents und Skills (5-Min-Cache, weil teuer).
seg_agt=""
seg_skl=""

agt_used=0; agt_bg=0; skl_used=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  counts=$(jq -rs '
    [.[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")] as $uses
    | ([.[] | select(.type=="user") | .message.content[]? | select(.type=="tool_result") | .tool_use_id] | unique) as $done
    | [
        ([$uses[] | select(.name=="Task" or .name=="Agent")] | length),
        ([$uses[] | select((.name=="Task" or .name=="Agent") and .input.run_in_background==true) | select((.id) as $i | ($done | index($i)) | not)] | length),
        ([$uses[] | select(.name=="Skill") | .input.skill] | unique | length)
      ] | @tsv
  ' "$transcript" 2>/dev/null)
  [ -n "$counts" ] && IFS=$'\t' read -r agt_used agt_bg skl_used <<< "$counts"
fi

# Available counts cachen (TTL 300 s) — find über ~/.claude/plugins/cache dauert ~1.5 s
cwd_hash=$(printf '%s' "$cwd" | md5 -q 2>/dev/null || printf '%s' "$cwd" | md5sum 2>/dev/null | cut -d' ' -f1)
avail_cache="${TMPDIR:-/tmp}/claude-statusline-avail-${cwd_hash}.cache"
agt_avail=0; skl_avail=0
if [ -f "$avail_cache" ] && [ $(($(date +%s) - $(stat -f %m "$avail_cache" 2>/dev/null || stat -c %Y "$avail_cache" 2>/dev/null || echo 0))) -lt 300 ]; then
  read -r agt_avail skl_avail < "$avail_cache"
else
  agt_avail=$({
    ls "$HOME/.claude/agents/"*.md 2>/dev/null
    [ -d "$cwd/.claude/agents" ] && ls "$cwd/.claude/agents/"*.md 2>/dev/null
    find "$HOME/.claude/plugins/cache" -path '*/agents/*.md' -not -path '*/temp_git_*' 2>/dev/null
  } | sed 's|.*/||;s|\.md$||' | sort -u | grep -c .)
  skl_avail=$({
    find "$HOME/.claude/skills" -maxdepth 3 -name SKILL.md 2>/dev/null
    [ -d "$cwd/.claude/skills" ] && find "$cwd/.claude/skills" -maxdepth 3 -name SKILL.md 2>/dev/null
    find "$HOME/.claude/plugins/cache" -name SKILL.md -not -path '*/temp_git_*' 2>/dev/null
  } | sed 's|/SKILL\.md$||;s|.*/||' | sort -u | grep -c .)
  printf '%s %s\n' "$agt_avail" "$skl_avail" > "$avail_cache"
fi

if [ "${agt_avail:-0}" -gt 0 ] 2>/dev/null; then
  if [ "${agt_bg:-0}" -gt 0 ] 2>/dev/null; then
    seg_agt="${C_AGT}agt ${agt_used}/${agt_avail} +${agt_bg}bg${RESET}"
  else
    seg_agt="${C_AGT}agt ${agt_used}/${agt_avail}${RESET}"
  fi
fi
if [ "${skl_avail:-0}" -gt 0 ] 2>/dev/null; then
  seg_skl="${C_SKL}skl ${skl_used}/${skl_avail}${RESET}"
fi

# --- Segment 6: Vim-Mode ---
seg_vim=""
if [ -n "$vim_mode" ]; then
  seg_vim="${C_CTX}[${vim_mode}]${RESET}"
fi

# --- Statusline zusammensetzen ---
line="${seg_dir}"
[ -n "$seg_git"   ] && line="${line}${SEP}${seg_git}"
[ -n "$seg_model" ] && line="${line}${SEP}${seg_model}"
[ -n "$seg_ctx"        ] && line="${line}${SEP}${seg_ctx}"
[ -n "$seg_rate"       ] && line="${line}${SEP}${seg_rate}"
[ -n "$seg_weekly"     ] && line="${line}${SEP}${seg_weekly}"
[ -n "$seg_weekly_opus" ] && line="${line}${SEP}${seg_weekly_opus}"
[ -n "$seg_agt"        ] && line="${line}${SEP}${seg_agt}"
[ -n "$seg_skl"        ] && line="${line}${SEP}${seg_skl}"
[ -n "$seg_vim"        ] && line="${line}${SEP}${seg_vim}"

printf "%b" "$line"
