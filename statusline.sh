#!/bin/bash
# Claude Code statusline
# Rate-limit values are cached to a temp file so the section never goes blank
# between API calls — staleness is shown as "(cached Xm ago)".

input=$(cat)
_CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Scoped by uid AND config dir so cached rate-limit values never bleed across
# accounts/profiles on machines that run more than one CLAUDE_CONFIG_DIR.
CACHE_FILE="${TMPDIR:-/tmp}/.claude_rl_$(id -u 2>/dev/null || echo 0)_$(basename "$_CLAUDE_CFG")"

# ── parse JSON ────────────────────────────────────────────────────────────────
MODEL=$(echo "$input"     | jq -r '.model.display_name // "unknown"')
DIR=$(echo "$input"       | jq -r '.workspace.current_dir // ""')
SESSION_ID=$(echo "$input"| jq -r '.session_id // empty')
REPO_OWNER=$(echo "$input"| jq -r '.workspace.repo.owner // empty')
REPO_NAME=$(echo "$input" | jq -r '.workspace.repo.name // empty')
SESSION=$(echo "$input"   | jq -r '.session_name // empty')
VERSION=$(echo "$input"   | jq -r '.version // ""')
VIM_MODE=$(echo "$input"  | jq -r '.vim.mode // empty')
AGENT=$(echo "$input"     | jq -r '.agent.name // empty')
WT_BRANCH=$(echo "$input" | jq -r '.worktree.branch // empty')
EFFORT=$(echo "$input"    | jq -r '.effort.level // empty')
THINKING=$(echo "$input"  | jq -r '.thinking.enabled // empty')
FAST_MODE=$(echo "$input" | jq -r '.fast_mode // empty')
# Tolerate output_style being either an object ({"name":"…"}) or a bare string.
OUT_STYLE=$(echo "$input" | jq -r '.output_style.name? // .output_style? // empty')
PR_NUM=$(echo "$input"    | jq -r '.pr.number // empty')
PR_STATE=$(echo "$input"  | jq -r '.pr.review_state // empty')

CTX_SIZE=$(echo "$input"  | jq -r '.context_window.context_window_size // 0')
EXCEEDS_200K=$(echo "$input" | jq -r '.exceeds_200k_tokens // empty')
USED_PCT=$(echo "$input"  | jq -r '.context_window.used_percentage // empty')
REM_PCT=$(echo "$input"   | jq -r '.context_window.remaining_percentage // empty')
IN_TOK=$(echo "$input"    | jq -r '.context_window.current_usage.input_tokens // empty')
OUT_TOK=$(echo "$input"   | jq -r '.context_window.current_usage.output_tokens // empty')
CACHE_W=$(echo "$input"   | jq -r '.context_window.current_usage.cache_creation_input_tokens // empty')
CACHE_R=$(echo "$input"   | jq -r '.context_window.current_usage.cache_read_input_tokens // empty')

COST_USD=$(echo "$input"  | jq -r '.cost.total_cost_usd // empty')
DUR_MS=$(echo "$input"    | jq -r '.cost.total_duration_ms // empty')
API_MS=$(echo "$input"    | jq -r '.cost.total_api_duration_ms // empty')
LINES_ADD=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
LINES_DEL=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')

FIVE_HR=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_RST=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_DAY=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
SEVEN_RST=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# ── rate-limit caching ────────────────────────────────────────────────────────
# Claude Code only includes rate_limits when it gets fresh headers from the API.
# Persist the last known values so the bars don't disappear between messages.
RATE_FRESH=0
CACHE_TS=""
if [ -n "$FIVE_HR" ] || [ -n "$SEVEN_DAY" ]; then
  RATE_FRESH=1
  printf '%s\t%s\t%s\t%s\t%d\n' \
    "${FIVE_HR:-}" "${FIVE_RST:-}" "${SEVEN_DAY:-}" "${SEVEN_RST:-}" "$(date +%s)" \
    > "$CACHE_FILE" 2>/dev/null
elif [ -f "$CACHE_FILE" ]; then
  IFS=$'\t' read -r FIVE_HR FIVE_RST SEVEN_DAY SEVEN_RST CACHE_TS < "$CACHE_FILE"
fi

# ── account / plan ────────────────────────────────────────────────────────────
ACCOUNT_EMAIL="" ACCOUNT_ORG="" PLAN_NAME=""

for _cc in "$_CLAUDE_CFG/.claude.json" "$HOME/.claude.json"; do
  [ -f "$_cc" ] || continue
  _email=$(jq -r '.oauthAccount.emailAddress // empty' "$_cc" 2>/dev/null)
  [ -n "$_email" ] && [ "$_email" != "null" ] || continue
  ACCOUNT_EMAIL="$_email"
  ACCOUNT_ORG=$(jq -r '.oauthAccount.organizationName // empty' "$_cc" 2>/dev/null)
  _tier=$(jq -r '(.oauthAccount.userRateLimitTier // .oauthAccount.organizationRateLimitTier) // empty' "$_cc" 2>/dev/null)
  _extra=$(jq -r '.oauthAccount.hasExtraUsageEnabled // false' "$_cc" 2>/dev/null)
  case "$_tier" in
    *max_20x*)                   PLAN_NAME="Max 20x" ;;
    *max_5x*)                    PLAN_NAME="Max 5x" ;;
    *max_1x*)                    PLAN_NAME="Max 1x" ;;
    *claude_pro*|*default_claude_ai*)
      [ "$_extra" = "true" ] && PLAN_NAME="Max" || PLAN_NAME="Pro" ;;
    "") ;;
    *) PLAN_NAME="$_tier" ;;
  esac
  break
done
# Fallback: derive label from config dir name when no auth file found
if [ -z "$ACCOUNT_EMAIL" ]; then
  _dn=$(basename "$_CLAUDE_CFG")
  if [ "$_dn" != ".claude" ] && [ "$_dn" != "claude" ]; then
    ACCOUNT_EMAIL="${_dn#.claude-}"; ACCOUNT_EMAIL="${ACCOUNT_EMAIL#claude-}"
  fi
fi

# ── colours ───────────────────────────────────────────────────────────────────
# Vibrant 256-colour palette — neon-bright so the line pops in any terminal.
CYAN='\033[38;5;51m'      # electric cyan
BLUE='\033[38;5;39m'      # vivid azure
GREEN='\033[38;5;46m'     # neon green
YELLOW='\033[38;5;226m'   # bright yellow
RED='\033[38;5;196m'      # hot red
MAGENTA='\033[38;5;201m'  # hot pink/magenta
ORANGE='\033[38;5;208m'   # bright orange
PURPLE='\033[38;5;141m'   # soft violet
PINK='\033[38;5;213m'     # bubblegum pink
BOLD='\033[1m'; RESET='\033[0m'

# "DIM" is the colour of labels / secondary text. We want it WHITE on a dark
# background but GREY on a light one. A script can't see the terminal background
# directly, so detect it via $COLORFGBG ("foreground;background", exported by
# many terminals) when available. Terminals that DON'T export it (e.g. macOS
# Terminal.app) are assumed dark — the common case — so labels default to white.
# Force either mode explicitly with CLAUDE_STATUSLINE_BG=light|dark.
# Empty bar segments stay a fixed muted grey regardless of background, so the
# unfilled portion never lights up (a background-adaptive white DIM would make
# the bars look almost full on dark terminals).
BAR_EMPTY='\033[38;5;240m'
# 20-step green→yellow→orange→red ramp. Each bar cell is coloured by its own
# position, so a filling bar glides through the spectrum and a full bar is a
# green-to-red gradient — an at-a-glance "fuel gauge" of how deep into the red
# the usage is.
GRAD=(46 46 82 82 118 154 190 226 226 220 214 214 208 208 202 202 196 196 160 124)
DIM='\033[38;5;255m'   # default: assume dark background → white labels
case "$CLAUDE_STATUSLINE_BG" in
  light) DIM='\033[38;5;245m' ;;
  dark)  DIM='\033[38;5;255m' ;;
  *)
    if [ -n "$COLORFGBG" ]; then
      _bg="${COLORFGBG##*;}"
      case "$_bg" in
        7|9|10|11|12|13|14|15) DIM='\033[38;5;245m' ;;  # light background → grey
      esac
    fi
    ;;
esac

# ── helpers ───────────────────────────────────────────────────────────────────
# make_spark PCT... — renders a sparkline from a series of integer percentages,
# each glyph sized by its value and coloured with the same green→red ramp as the
# bars, so the context-usage trend reads at a glance.
SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
make_spark() {
  local out="" v idx cidx
  for v in "$@"; do
    [ "$v" -gt 100 ] 2>/dev/null && v=100; [ "$v" -lt 0 ] 2>/dev/null && v=0
    idx=$(( v * 7 / 100 ));   [ "$idx" -gt 7 ]   && idx=7
    cidx=$(( v * 19 / 100 )); [ "$cidx" -gt 19 ] && cidx=19
    out="${out}\033[38;5;${GRAD[cidx]}m${SPARK_CHARS[idx]}"
  done
  printf "%b" "$out"
}

# make_bar PCT — renders a 20-cell gradient bar. (A second colour arg is still
# accepted but ignored; the per-cell gradient replaces the old flat colour.)
make_bar() {
  local pct="${1:-0}"
  local ipct; ipct=$(printf '%.0f' "$pct" 2>/dev/null) || ipct=0
  [ "$ipct" -gt 100 ] && ipct=100
  [ "$ipct" -lt 0 ]   && ipct=0
  local filled=$(( (ipct * 20 + 50) / 100 ))
  [ "$filled" -gt 20 ] && filled=20
  local out="" i
  for (( i = 0; i < filled; i++ )); do
    out="${out}\033[38;5;${GRAD[i]}m█"
  done
  local empty=$(( 20 - filled ))
  printf -v E "%${empty}s" ""
  printf "%b%b%s" "$out" "$BAR_EMPTY" "${E// /░}"
}

fmt_k() {
  local n="${1:-}"
  [ -z "$n" ] || [ "$n" = "null" ] && echo "—" && return
  [ "$n" -ge 1000 ] 2>/dev/null && printf '%dk' $(( n / 1000 )) || printf '%d' "$n"
}

fmt_usd() {
  local n="${1:-}"
  [ -z "$n" ] || [ "$n" = "null" ] && echo "—" && return
  printf '$%.2f' "$n" 2>/dev/null || echo "—"
}

fmt_dur() {
  local ms="${1:-}"
  [ -z "$ms" ] || [ "$ms" = "null" ] && echo "—" && return
  local secs=$(( ms / 1000 ))
  # Sub-minute durations (common for API waits) show seconds instead of "0m".
  [ "$secs" -lt 60 ] && { printf '%ds' "$secs"; return; }
  local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
  [ "$h" -gt 0 ] && printf '%dh%dm' "$h" "$m" || printf '%dm' "$m"
}

fmt_reset() {
  local epoch="${1:-}"
  # Pass a non-empty second arg to prefix the date (e.g. weekly resets days out).
  local with_date="${2:-}"
  [ -z "$epoch" ] || [ "$epoch" = "null" ] && return
  local now; now=$(date +%s)
  local diff=$(( epoch - now ))
  [ "$diff" -le 0 ] && echo "now" && return
  local h=$(( diff / 3600 )) m=$(( (diff % 3600) / 60 ))
  # Absolute wall-clock time the limit resets at — BSD (macOS) vs GNU date.
  local fmt='+%-I:%M%p'
  [ -n "$with_date" ] && fmt='+%a %-m/%-d %-I:%M%p'
  local clock
  clock=$(date -r "$epoch" "$fmt" 2>/dev/null || date -d "@$epoch" "$fmt" 2>/dev/null)
  clock=$(echo "$clock" | tr '[:upper:]' '[:lower:]')
  local clock_part=""
  [ -n "$clock" ] && clock_part=" (${clock})"
  [ "$h" -gt 0 ] && printf '%dh%dm%s' "$h" "$m" "$clock_part" || printf '%dm%s' "$m" "$clock_part"
}

fmt_age() {
  local ts="${1:-}"
  [ -z "$ts" ] && return
  local now; now=$(date +%s)
  local age=$(( now - ts ))
  if   [ "$age" -lt 60 ];   then printf '%ds' "$age"
  elif [ "$age" -lt 3600 ]; then printf '%dm' $(( age / 60 ))
  else                           printf '%dh' $(( age / 3600 ))
  fi
}

# ── line 1: model / session / account / plan / dir / branch ──────────────────
SESSION_PART=""
[ -n "$SESSION" ] && SESSION_PART=" ${DIM}(${SESSION})${RESET}"

BRANCH=""
GIT_DIR=$(git -C "$DIR" rev-parse --git-dir 2>/dev/null)
if [ -n "$GIT_DIR" ]; then
  BR=$(git -C "$DIR" -c core.useReplacement=false branch --show-current 2>/dev/null)
  [ -n "$WT_BRANCH" ] && BR="$WT_BRANCH"

  # A single porcelain call yields both upstream divergence and working-tree
  # state, so we summarise the repo right next to the branch name:
  #   ⇡n ahead / ⇣n behind upstream · ●n staged · ✎n modified · …n untracked
  #   ✓ when the tree is clean.
  GIT_STATE=""
  _porc=$(git -C "$DIR" status --porcelain=v1 --branch 2>/dev/null)
  if [ -n "$_porc" ]; then
    _staged=0 _modified=0 _untracked=0 _ahead=0 _behind=0
    while IFS= read -r _l; do
      case "$_l" in
        '## '*)
          case "$_l" in *'[ahead '*)  _ahead=${_l##*'[ahead '};  _ahead=${_ahead%%[,\]]*} ;; esac
          case "$_l" in *'behind '*)   _behind=${_l##*'behind '}; _behind=${_behind%%]*} ;; esac
          ;;
        '??'*) _untracked=$(( _untracked + 1 )) ;;
        ??*)
          _x=${_l:0:1} _y=${_l:1:1}
          [ "$_x" != " " ] && _staged=$(( _staged + 1 ))
          [ "$_y" != " " ] && _modified=$(( _modified + 1 ))
          ;;
      esac
    done <<< "$_porc"

    _div=""
    [ "$_ahead"  -gt 0 ] 2>/dev/null && _div="${_div} ${CYAN}⇡${_ahead}${RESET}"
    [ "$_behind" -gt 0 ] 2>/dev/null && _div="${_div} ${YELLOW}⇣${_behind}${RESET}"

    _wt=""
    [ "$_staged"    -gt 0 ] && _wt="${_wt} ${GREEN}●${_staged}${RESET}"
    [ "$_modified"  -gt 0 ] && _wt="${_wt} ${ORANGE}✎${_modified}${RESET}"
    [ "$_untracked" -gt 0 ] && _wt="${_wt} ${DIM}…${_untracked}${RESET}"

    if [ -z "$_wt" ]; then
      GIT_STATE="${_div} ${GREEN}✓${RESET}"
    else
      GIT_STATE="${_div}${_wt}"
    fi
  fi

  [ -n "$BR" ] && BRANCH=" ${DIM}on${RESET} ${BOLD}${MAGENTA}🌿 ${BR}${RESET}${GIT_STATE}"
fi

# Open-PR badge, coloured by review state.
PR_PART=""
if [ -n "$PR_NUM" ]; then
  case "$PR_STATE" in
    approved)          _pc="$GREEN";  _ps=" ✓" ;;
    changes_requested) _pc="$RED";    _ps=" ✗" ;;
    pending)           _pc="$YELLOW"; _ps="" ;;
    draft)             _pc="$DIM";    _ps=" ✎" ;;
    *)                 _pc="$CYAN";   _ps="" ;;
  esac
  PR_PART=" ${BOLD}${_pc}🔀 #${PR_NUM}${_ps}${RESET}"
fi

# Reasoning-effort badge — escalates from a calm turtle to a rocket. This tracks
# the /effort toggle and re-renders when it changes.
EFFORT_PART=""
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low)    _ec="$BLUE";    _ee="🐢" ;;
    medium) _ec="$CYAN";    _ee="⚙️" ;;
    high)   _ec="$YELLOW";  _ee="⚡" ;;
    xhigh)  _ec="$ORANGE";  _ee="🔥" ;;
    max)    _ec="$MAGENTA"; _ee="🚀" ;;
    *)      _ec="$CYAN";    _ee="⚙️" ;;
  esac
  EFFORT_PART=" ${BOLD}${_ec}${_ee} ${EFFORT}${RESET}"
fi

# Extended-thinking indicator.
THINK_PART=""
[ "$THINKING" = "true" ] && THINK_PART=" ${PURPLE}💭${RESET}"

# Fast-mode toggle (/fast) — only shown when engaged.
FAST_PART=""
[ "$FAST_MODE" = "true" ] && FAST_PART=" ${BOLD}${GREEN}🏎️  fast${RESET}"

# Output style, shown only when it isn't the default.
STYLE_PART=""
[ -n "$OUT_STYLE" ] && [ "$OUT_STYLE" != "default" ] \
  && STYLE_PART=" ${PINK}🎨 ${OUT_STYLE}${RESET}"

AGENT_PART=""
[ -n "$AGENT" ] && AGENT_PART=" ${BOLD}${ORANGE}🛠️  ${AGENT}${RESET}"

VIM_PART=""
[ -n "$VIM_MODE" ] && VIM_PART=" ${BOLD}${BLUE}[${VIM_MODE}]${RESET}"

VER_PART=""
[ -n "$VERSION" ] && VER_PART=" ${DIM}v${VERSION}${RESET}"

ACCT_PART=""
if [ -n "$ACCOUNT_EMAIL" ]; then
  ACCT_PART=" ${DIM}as${RESET} ${PINK}👤 ${ACCOUNT_EMAIL}${RESET}"
  [ -n "$ACCOUNT_ORG" ] && ACCT_PART="${ACCT_PART} ${DIM}@ ${ACCOUNT_ORG}${RESET}"
fi

PLAN_PART=""
[ -n "$PLAN_NAME" ] && PLAN_PART=" ${DIM}[${RESET}${BOLD}${PURPLE}✨ ${PLAN_NAME}${RESET}${DIM}]${RESET}"

# Repo identity (owner/name) — handy when the folder name differs from the repo.
REPO_PART=""
[ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ] \
  && REPO_PART=" ${DIM}(${RESET}${CYAN}${REPO_OWNER}/${REPO_NAME}${RESET}${DIM})${RESET}"

# Give each model family its own accent colour so the robot has a personality.
MODEL_COLOR="$CYAN"
case "$MODEL" in
  *[Oo]pus*)   MODEL_COLOR="$PURPLE" ;;
  *[Ss]onnet*) MODEL_COLOR="$CYAN" ;;
  *[Hh]aiku*)  MODEL_COLOR="$GREEN" ;;
esac

# Assemble into a variable and print with a constant %b format so a literal '%'
# in any dynamic value (model, session, dir, branch, account) isn't treated as
# a printf format specifier.
LINE1="${BOLD}${MODEL_COLOR}🤖 ${MODEL}${RESET}${VER_PART}${EFFORT_PART}${THINK_PART}${FAST_PART}${STYLE_PART}${SESSION_PART}${AGENT_PART}${VIM_PART}${ACCT_PART}${PLAN_PART}  ${BOLD}${BLUE}📂 ${DIR##*/}${RESET}${REPO_PART}${BRANCH}${PR_PART}"
printf '%b\n' "$LINE1"

# ── line 2: context window bar + token counts ─────────────────────────────────
if [ -n "$USED_PCT" ]; then
  PCT=$(printf '%.0f' "$USED_PCT" 2>/dev/null || echo 0)
  REM=$(printf '%.0f' "${REM_PCT:-$(( 100 - PCT ))}" 2>/dev/null || echo 0)

  if   [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
  elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
  else BAR_COLOR="$GREEN"; fi

  BAR=$(make_bar "$PCT" "$BAR_COLOR")

  # The brain reflects how full the window is: calm → sweating → overheating.
  CTX_EMOJI="🧠"
  if   [ "$PCT" -ge 90 ]; then CTX_EMOJI="🥵"
  elif [ "$PCT" -ge 70 ]; then CTX_EMOJI="😅"; fi

  TOK_DETAIL=""
  if [ -n "$IN_TOK" ]; then
    TOK_DETAIL=" ${DIM}in:${RESET}$(fmt_k "$IN_TOK") ${DIM}out:${RESET}$(fmt_k "$OUT_TOK")"
    [ -n "$CACHE_R" ] && [ "$CACHE_R" -gt 0 ] 2>/dev/null \
      && TOK_DETAIL="${TOK_DETAIL} ${DIM}cr:${RESET}$(fmt_k "$CACHE_R")"
    [ -n "$CACHE_W" ] && [ "$CACHE_W" -gt 0 ] 2>/dev/null \
      && TOK_DETAIL="${TOK_DETAIL} ${DIM}cw:${RESET}$(fmt_k "$CACHE_W")"

    # Cache-hit %: fraction of the input context served from prompt cache,
    # i.e. cache_read ÷ (input + cache_creation + cache_read).
    # Higher = more reuse = cheaper & faster.
    _cr=${CACHE_R:-0}; _cw=${CACHE_W:-0}; _it=${IN_TOK:-0}
    case "$_cr" in ''|*[!0-9]*) _cr=0 ;; esac
    case "$_cw" in ''|*[!0-9]*) _cw=0 ;; esac
    case "$_it" in ''|*[!0-9]*) _it=0 ;; esac
    _tot=$(( _it + _cw + _cr ))
    if [ "$_cr" -gt 0 ] && [ "$_tot" -gt 0 ]; then
      _hit=$(( _cr * 100 / _tot ))
      if   [ "$_hit" -ge 80 ]; then _hc="$GREEN"
      elif [ "$_hit" -ge 50 ]; then _hc="$YELLOW"
      else _hc="$ORANGE"; fi
      TOK_DETAIL="${TOK_DETAIL} ${_hc}💾 ${_hit}%${RESET}"
    fi
  fi

  # Flag when the conversation has crossed the 200k-token threshold.
  EXCEED_PART=""
  [ "$EXCEEDS_200K" = "true" ] && EXCEED_PART=" ${BOLD}${RED}⚠️ 200k+${RESET}"

  # Context-usage sparkline + runway. We keep a small per-session history of
  # (timestamp, used-%) pairs so we can both draw the trend and project how long
  # until the window is full. Samples are throttled to at most one every 8s (so
  # the line tracks real elapsed time, not render frequency) and capped at the
  # last 20 points. History lives in a per-session temp file.
  SPARK_PART=""
  RUNWAY_PART=""
  if [ -n "$SESSION_ID" ]; then
    # Sanitise the session id before putting it in a path — keep only filename-
    # safe characters so a stray '/' or space can't redirect the write.
    _safe_sid="${SESSION_ID//[^A-Za-z0-9._-]/}"
    SPARK_FILE="${TMPDIR:-/tmp}/.claude_spark2_$(id -u 2>/dev/null || echo 0)_${_safe_sid}"
    _now=$(date +%s); _hist=""
    if [ -f "$SPARK_FILE" ]; then
      _hist=$(cat "$SPARK_FILE" 2>/dev/null)
    else
      # First sample of a new session — opportunistically sweep spark files from
      # sessions untouched for a day so temp files don't accumulate forever.
      find "${TMPDIR:-/tmp}" -maxdepth 1 -name '.claude_spark*' -mtime +1 -delete 2>/dev/null
    fi
    # Parse the flat "ts val ts val …" list into parallel arrays.
    _ts=(); _vs=(); _i=0
    # shellcheck disable=SC2086
    for _tok in $_hist; do
      if [ $(( _i % 2 )) -eq 0 ]; then _ts+=("$_tok"); else _vs+=("$_tok"); fi
      _i=$(( _i + 1 ))
    done
    # Drop a trailing unpaired token from a truncated write, if any.
    [ "${#_ts[@]}" -gt "${#_vs[@]}" ] && _ts=("${_ts[@]:0:${#_vs[@]}}")
    _np=${#_vs[@]}
    _lastts=0; [ "$_np" -ge 1 ] && _lastts=${_ts[$(( _np - 1 ))]}
    case "$_lastts" in ''|*[!0-9]*) _lastts=0 ;; esac

    if [ $(( _now - _lastts )) -ge 8 ]; then
      _ts+=("$_now"); _vs+=("$PCT"); _np=${#_vs[@]}
      if [ "$_np" -gt 20 ]; then
        _ts=("${_ts[@]:$(( _np - 20 ))}"); _vs=("${_vs[@]:$(( _np - 20 ))}"); _np=20
      fi
      _out=""; for (( _i = 0; _i < _np; _i++ )); do _out="$_out ${_ts[_i]} ${_vs[_i]}"; done
      printf '%s\n' "${_out# }" > "$SPARK_FILE" 2>/dev/null
    fi

    [ "$_np" -ge 2 ] && SPARK_PART=" ${DIM}📈${RESET} $(make_spark "${_vs[@]}")${RESET}"

    # Runway: linear projection to 100% from the oldest→newest retained samples.
    # Only shown when context is genuinely climbing over a meaningful window, so
    # it stays quiet during noise or when usage is flat/shrinking.
    if [ "$_np" -ge 3 ]; then
      _v0=${_vs[0]}; _vn=${_vs[$(( _np - 1 ))]}
      _t0=${_ts[0]}; _tn=${_ts[$(( _np - 1 ))]}
      _dv=$(( _vn - _v0 )); _dt=$(( _tn - _t0 ))
      if [ "$_dv" -ge 2 ] && [ "$_dt" -ge 30 ] && [ "$_vn" -lt 100 ]; then
        _eta=$(( (100 - _vn) * _dt / _dv ))               # seconds to full
        [ "$_eta" -gt 0 ] && [ "$_eta" -lt 86400 ] \
          && RUNWAY_PART=" ${DIM}🛫${RESET} ${YELLOW}$(fmt_dur $(( _eta * 1000 )))${RESET}${DIM} to full${RESET}"
      fi
    fi
  fi

  CTX_K=$(fmt_k "$CTX_SIZE")
  # Assemble and print with a constant %b format so a literal '%' in any dynamic
  # segment (e.g. the cache-hit badge) isn't treated as a printf format spec.
  LINE2="${BOLD}${PURPLE}${CTX_EMOJI} ctx${RESET} ${BAR}${RESET} ${BOLD}${BAR_COLOR}${PCT}%${RESET} ${DIM}rem:${RESET}${GREEN}${REM}%${RESET}${SPARK_PART}${RUNWAY_PART}${TOK_DETAIL} ${DIM}ctx:${RESET}${CYAN}${CTX_K}${RESET}${EXCEED_PART}"
  printf '%b\n' "$LINE2"
else
  printf "${PURPLE}🧠 ${DIM}ctx: waiting for first message…${RESET}\n"
fi

# ── line: session cost / duration / lines changed ─────────────────────────────
if [ -n "$COST_USD" ]; then
  LINES_PART=""
  if [ -n "$LINES_ADD" ] && [ -n "$LINES_DEL" ]; then
    LINES_PART=" ${DIM}(${RESET}${GREEN}+${LINES_ADD}${RESET}${DIM}/${RESET}${RED}-${LINES_DEL}${RESET}${DIM})${RESET}"
    # Code-change velocity: total lines touched per hour over the session.
    if [ -n "$DUR_MS" ] && [ "$DUR_MS" -gt 0 ] 2>/dev/null; then
      _la=$LINES_ADD; case "$_la" in ''|*[!0-9]*) _la=0 ;; esac
      _ld=$LINES_DEL; case "$_ld" in ''|*[!0-9]*) _ld=0 ;; esac
      _lph=$(( (_la + _ld) * 3600000 / DUR_MS ))
      [ "$_lph" -gt 0 ] && LINES_PART="${LINES_PART} ${DIM}✏️  ${_lph}/hr${RESET}"
    fi
  fi
  DUR_PART=""
  [ -n "$DUR_MS" ] && DUR_PART=" ${DIM}·${RESET} ${DIM}⏱️  session:${RESET}${CYAN}$(fmt_dur "$DUR_MS")${RESET}"

  # How much of the session was spent waiting on the API.
  API_PART=""
  [ -n "$API_MS" ] && [ "$API_MS" -gt 0 ] 2>/dev/null \
    && API_PART=" ${DIM}·${RESET} ${DIM}🛰️  api:${RESET}${CYAN}$(fmt_dur "$API_MS")${RESET}"

  # Cost tier: 🪙 pocket change (<$1) · 💰 building up ($1–$9) · 💸 pricey (≥$10).
  COST_EMOJI="💰"
  _dollars=${COST_USD%%.*}; case "$_dollars" in ''|*[!0-9]*) _dollars=0 ;; esac
  if   [ "$_dollars" -ge 10 ]; then COST_EMOJI="💸"
  elif [ "$_dollars" -lt 1 ];  then COST_EMOJI="🪙"; fi

  # Cost velocity ($/hr) — spend rate over the whole session, with a burn emoji
  # that escalates: 🐢 <$1 · 🚶 $1–$4 · 🏃 $5–$14 · 🔥 ≥$15 per hour.
  VELO_PART=""
  if [ -n "$DUR_MS" ] && [ "$DUR_MS" -gt 0 ] 2>/dev/null; then
    _rate=$(awk -v c="$COST_USD" -v d="$DUR_MS" 'BEGIN{ printf "%.2f", c*3600000/d }' 2>/dev/null)
    _ri=${_rate%.*}; case "$_ri" in ''|*[!0-9]*) _ri=0 ;; esac
    if   [ "$_ri" -ge 15 ]; then _be="🔥"; _bc="$RED"
    elif [ "$_ri" -ge 5 ];  then _be="🏃"; _bc="$ORANGE"
    elif [ "$_ri" -ge 1 ];  then _be="🚶"; _bc="$YELLOW"
    else                         _be="🐢"; _bc="$GREEN"; fi
    [ -n "$_rate" ] && VELO_PART=" ${DIM}·${RESET} ${_bc}${_be} \$${_rate}/hr${RESET}"
  fi

  printf "${BOLD}${GREEN}${COST_EMOJI} cost${RESET} ${BOLD}${YELLOW}$(fmt_usd "$COST_USD")${RESET}${LINES_PART}${DUR_PART}${API_PART}${VELO_PART}\n"
fi

# ── line 4: rate limits ───────────────────────────────────────────────────────
if [ -n "$FIVE_HR" ] || [ -n "$SEVEN_DAY" ]; then
  STALE_PART=""
  if [ "$RATE_FRESH" -eq 0 ] && [ -n "$CACHE_TS" ]; then
    AGE=$(fmt_age "$CACHE_TS")
    STALE_PART=" ${DIM}(cached ${AGE} ago)${RESET}"
  fi

  RATE_LINE=""
  if [ -n "$FIVE_HR" ] && [ "$FIVE_HR" != "null" ]; then
    P=$(printf '%.0f' "$FIVE_HR" 2>/dev/null || echo 0)
    if   [ "$P" -ge 90 ]; then RC="$RED"
    elif [ "$P" -ge 70 ]; then RC="$YELLOW"
    else RC="$GREEN"; fi
    BAR5=$(make_bar "$P" "$RC")
    RST5=$(fmt_reset "$FIVE_RST")
    RST5_PART=""; [ -n "$RST5" ] && RST5_PART=" ${DIM}resets${RESET} ${RST5}"
    RATE_LINE="${BOLD}${ORANGE}⚡ 5h${RESET} ${BAR5}${RESET} ${BOLD}${RC}${P}%${RESET}${RST5_PART}"
  fi

  if [ -n "$SEVEN_DAY" ] && [ "$SEVEN_DAY" != "null" ]; then
    P=$(printf '%.0f' "$SEVEN_DAY" 2>/dev/null || echo 0)
    if   [ "$P" -ge 90 ]; then RC="$RED"
    elif [ "$P" -ge 70 ]; then RC="$YELLOW"
    else RC="$GREEN"; fi
    BAR7=$(make_bar "$P" "$RC")
    RST7=$(fmt_reset "$SEVEN_RST" with_date)
    RST7_PART=""; [ -n "$RST7" ] && RST7_PART=" ${DIM}resets${RESET} ${RST7}"
    [ -n "$RATE_LINE" ] && RATE_LINE="${RATE_LINE}  "
    RATE_LINE="${RATE_LINE}${BOLD}${PINK}📅 7d${RESET} ${BAR7}${RESET} ${BOLD}${RC}${P}%${RESET}${RST7_PART}"
  fi

  printf "%b%b\n" "$RATE_LINE" "$STALE_PART"
fi
