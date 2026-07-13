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
SESSION=$(echo "$input"   | jq -r '.session_name // empty')
VERSION=$(echo "$input"   | jq -r '.version // ""')
VIM_MODE=$(echo "$input"  | jq -r '.vim.mode // empty')
AGENT=$(echo "$input"     | jq -r '.agent.name // empty')
WT_BRANCH=$(echo "$input" | jq -r '.worktree.branch // empty')
EFFORT=$(echo "$input"    | jq -r '.effort.level // empty')
THINKING=$(echo "$input"  | jq -r '.thinking.enabled // empty')
FAST_MODE=$(echo "$input" | jq -r '.fast_mode // empty')
OUT_STYLE=$(echo "$input" | jq -r '.output_style.name // empty')
PR_NUM=$(echo "$input"    | jq -r '.pr.number // empty')
PR_STATE=$(echo "$input"  | jq -r '.pr.review_state // empty')

CTX_SIZE=$(echo "$input"  | jq -r '.context_window.context_window_size // 0')
USED_PCT=$(echo "$input"  | jq -r '.context_window.used_percentage // empty')
REM_PCT=$(echo "$input"   | jq -r '.context_window.remaining_percentage // empty')
IN_TOK=$(echo "$input"    | jq -r '.context_window.current_usage.input_tokens // empty')
OUT_TOK=$(echo "$input"   | jq -r '.context_window.current_usage.output_tokens // empty')
CACHE_W=$(echo "$input"   | jq -r '.context_window.current_usage.cache_creation_input_tokens // empty')
CACHE_R=$(echo "$input"   | jq -r '.context_window.current_usage.cache_read_input_tokens // empty')

COST_USD=$(echo "$input"  | jq -r '.cost.total_cost_usd // empty')
DUR_MS=$(echo "$input"    | jq -r '.cost.total_duration_ms // empty')
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
make_bar() {
  local pct="${1:-0}" color="$2"
  local ipct; ipct=$(printf '%.0f' "$pct" 2>/dev/null) || ipct=0
  [ "$ipct" -gt 100 ] && ipct=100
  local filled=$(( (ipct * 20 + 50) / 100 ))
  [ "$filled" -gt 20 ] && filled=20
  local empty=$(( 20 - filled ))
  printf -v F "%${filled}s" ""; printf -v E "%${empty}s" ""
  printf "%b%s%b%s" "$color" "${F// /█}" "$BAR_EMPTY" "${E// /░}"
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
LINE1="${BOLD}${MODEL_COLOR}🤖 ${MODEL}${RESET}${VER_PART}${EFFORT_PART}${THINK_PART}${FAST_PART}${STYLE_PART}${SESSION_PART}${AGENT_PART}${VIM_PART}${ACCT_PART}${PLAN_PART}  ${BOLD}${BLUE}📂 ${DIR##*/}${RESET}${BRANCH}${PR_PART}"
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
  fi

  CTX_K=$(fmt_k "$CTX_SIZE")
  printf "%b %b${RESET} ${BOLD}${BAR_COLOR}${PCT}%%${RESET} ${DIM}rem:${RESET}${GREEN}${REM}%%${RESET}${TOK_DETAIL} ${DIM}ctx:${RESET}${CYAN}${CTX_K}${RESET}\n" \
    "${BOLD}${PURPLE}${CTX_EMOJI} ctx${RESET}" "$BAR"
else
  printf "${PURPLE}🧠 ${DIM}ctx: waiting for first message…${RESET}\n"
fi

# ── line: session cost / duration / lines changed ─────────────────────────────
if [ -n "$COST_USD" ]; then
  LINES_PART=""
  if [ -n "$LINES_ADD" ] && [ -n "$LINES_DEL" ]; then
    LINES_PART=" ${DIM}(${RESET}${GREEN}+${LINES_ADD}${RESET}${DIM}/${RESET}${RED}-${LINES_DEL}${RESET}${DIM})${RESET}"
  fi
  DUR_PART=""
  [ -n "$DUR_MS" ] && DUR_PART=" ${DIM}·${RESET} ${DIM}⏱️  session:${RESET}${CYAN}$(fmt_dur "$DUR_MS")${RESET}"
  printf "${BOLD}${GREEN}💰 cost${RESET} ${BOLD}${YELLOW}$(fmt_usd "$COST_USD")${RESET}${LINES_PART}${DUR_PART}\n"
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
