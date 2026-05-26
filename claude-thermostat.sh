#!/usr/bin/env bash
# claude-thermostat: in-session cost-threshold hook.
#
# Fires on every Stop event. Tracks session age, turn count, and real API
# cost (parsed from the transcript JSONL). When the setpoint is crossed it
# exits 2 so Claude sees the alert and relays it to the user with concrete
# options: /compact, /clear, close+pivot, or keep going.
#
# Fires once, then re-arms after CLAUDE_THERMOSTAT_COOLDOWN_TURNS more turns
# (the deadband) so long sessions get a periodic nudge without being spammy.
#
# Setpoints (override via env):
#   CLAUDE_THERMOSTAT_TIME_SEC        0     0 = disabled
#   CLAUDE_THERMOSTAT_TURNS           0     0 = disabled
#   CLAUDE_THERMOSTAT_COST_CENTS      5000  estimated cost in US cents ($50)
#   CLAUDE_THERMOSTAT_CONTEXT_K       0     0 = disabled
#   CLAUDE_THERMOSTAT_COOLDOWN_TURNS  10    turns between re-fires after first
#
# Subscription-window approximation (local math, not a real quota read):
#   CLAUDE_THERMOSTAT_WINDOW_SEC          18000  5h rolling window
#   CLAUDE_THERMOSTAT_WINDOW_TOKENS       0      token setpoint; 0 disables
#   CLAUDE_THERMOSTAT_WINDOW_COUNT_CACHED 1      1 weights cache_read at 1.0x
# When WINDOW_TOKENS is set, the alert and header show the rolling sum across
# every Claude Code transcript under ~/.claude/projects. See README for caveats.
#
# Wire-up (~/.claude/settings.json):
#   "Stop": [{ "hooks": [{ "type": "command",
#              "command": "/abs/path/to/claude-thermostat/claude-thermostat.sh" }] }]
#
# State lives at ~/.claude/thermostat/<session_id>.json.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export THERMOSTAT_LIB_DIR="$SCRIPT_DIR"

STATE_DIR="$HOME/.claude/thermostat"
mkdir -p "$STATE_DIR"

# Optional config file — shell snippet sourced so users can set
# CLAUDE_THERMOSTAT_* without polluting their shell rc. Sourced before
# env-var defaults are read, so values here override anything in the
# environment. Example contents (KEY=VAL, no `export` needed):
#   CLAUDE_THERMOSTAT_COST_CENTS=3000
#   CLAUDE_THERMOSTAT_COOLDOWN_TURNS=15
CONFIG_FILE="${CLAUDE_THERMOSTAT_CONFIG:-$STATE_DIR/config.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# Cost is the only setpoint enabled by default — short, expensive turns
# matter more than long, cheap ones. Time / turns / context are computed
# and shown in the alert header regardless, and any of them can be turned
# into a trigger by setting its env var to a non-zero threshold.
COST_THRESH="${CLAUDE_THERMOSTAT_COST_CENTS:-5000}"           # $50
TIME_THRESH="${CLAUDE_THERMOSTAT_TIME_SEC:-0}"                # 0 disables
TURNS_THRESH="${CLAUDE_THERMOSTAT_TURNS:-0}"                  # 0 disables
CONTEXT_THRESH_K="${CLAUDE_THERMOSTAT_CONTEXT_K:-0}"          # 0 disables
COOLDOWN_TURNS="${CLAUDE_THERMOSTAT_COOLDOWN_TURNS:-10}"
# Antipattern detection: fire the moment recurring waste is visible, even
# if the dollar setpoint isn't hit yet.
ANTIPATTERN_DETECT="${CLAUDE_THERMOSTAT_ANTIPATTERNS:-1}"     # 1 enables
# Subscription-window approximation. Off by default; setpoint of 0 hides it
# from the header so users on API billing don't see noise they don't need.
WINDOW_SEC="${CLAUDE_THERMOSTAT_WINDOW_SEC:-18000}"           # 5h
WINDOW_TOKENS_THRESH="${CLAUDE_THERMOSTAT_WINDOW_TOKENS:-0}"  # 0 disables
WINDOW_COUNT_CACHED="${CLAUDE_THERMOSTAT_WINDOW_COUNT_CACHED:-1}"

input="$(cat)"
now=$(date +%s)

{ read -r session_id; read -r stop_hook_active; read -r transcript_path; } < <(
  printf '%s' "$input" | /usr/bin/python3 -c \
    "import json,sys; d=json.load(sys.stdin); [print(d.get(k,'')) for k in ['session_id','stop_hook_active','transcript_path']]" 2>/dev/null
)
[ -z "$session_id" ] && exit 0

# Stop hooks re-activate Claude when exiting 2. stop_hook_active is set to
# true on that re-invocation so we don't loop.
if [ "$stop_hook_active" = "True" ] || [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

state_file="$STATE_DIR/${session_id}.json"

# --- state helpers -----------------------------------------------------------

read_state() {
  /usr/bin/python3 - "$state_file" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
print(d.get('session_start', 0))
print(d.get('turn_count', 0))
print(d.get('last_nag_turn', 0))
print(d.get('nag_count', 0))
PY
}

write_state() {
  SS="$1" TC="$2" LNT="$3" NC="$4" /usr/bin/python3 - "$state_file" <<'PY'
import json, os, sys
d = {
    'session_start':  int(os.environ['SS']),
    'turn_count':     int(os.environ['TC']),
    'last_nag_turn':  int(os.environ['LNT']),
    'nag_count':      int(os.environ['NC']),
}
json.dump(d, open(sys.argv[1], 'w'))
PY
}

# --- parse transcript for cost + context data --------------------------------

# Reads the session transcript JSONL and returns four lines:
#   total_cost_cents  (int, rounded)
#   last_context_k    (int, total input tokens of most recent turn / 1000)
#   model             (string, e.g. claude-sonnet-4-6)
#   assistant_turns   (int, number of assistant messages with usage)
#
# Only counts turns whose timestamp >= session_start so resumed sessions
# don't accumulate cost from prior conversations in the same file.
parse_transcript() {
  /usr/bin/python3 - "$transcript_path" "$session_start" <<'PY'
import json, sys, os
from collections import Counter
sys.path.insert(0, os.environ['THERMOSTAT_LIB_DIR'])
from _lib import is_real_user, in_session, turn_cost_usd, dedupe_turn

path       = sys.argv[1]
start_unix = int(sys.argv[2]) if len(sys.argv) > 2 else 0

if not path or not os.path.exists(path):
    # cost_cents, context_k, primary_model, turns, cache_hit_pct
    print(0); print(0); print('unknown'); print(0); print(0)
    sys.exit(0)

# Group assistant messages by user turn. Each turn entry is a list of
# (message.id, usage_dict). Claude Code re-appends the same assistant
# message on every tool round-trip with the same `msg_xxx` id; dedupe_turn
# collapses those before billing, so we don't double-count input/output/cw.

turns = []
turn_models = []
current_turn = []
current_model = None

with open(path, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        t = obj.get('type')
        if t == 'user':
            if not in_session(obj, start_unix):
                continue
            if is_real_user(obj):
                if current_turn:
                    turns.append(current_turn)
                    turn_models.append(current_model or 'unknown')
                    current_turn = []
                    current_model = None
        elif t == 'assistant':
            if not in_session(obj, start_unix):
                continue
            msg = obj.get('message', {})
            usage = msg.get('usage')
            if not usage:
                continue
            m = msg.get('model')
            # Track the FIRST model seen per turn (a mid-turn switch is rare
            # but tool round-trips re-emit the same model id anyway).
            if m and not current_model and m != '<synthetic>':
                current_model = m
            current_turn.append((msg.get('id'), usage))
if current_turn:
    turns.append(current_turn)
    turn_models.append(current_model or 'unknown')

total_cost_usd = 0.0
total_cr = total_paid_input = 0
last_context_tokens = 0
model_usd = Counter()

for turn, model in zip(turns, turn_models):
    if not turn:
        continue
    cost, inp, cw, cr, out = turn_cost_usd(turn, model)
    total_cost_usd += cost
    model_usd[model] += cost
    total_cr += cr
    total_paid_input += inp + cw
    # Context size = last unique usage row's total input footprint.
    usages = dedupe_turn(turn)
    last = usages[-1]
    last_context_tokens = (last.get('input_tokens', 0)
                           + last.get('cache_creation_input_tokens', 0)
                           + last.get('cache_read_input_tokens', 0))

primary_model = model_usd.most_common(1)[0][0] if model_usd else 'unknown'
cache_hit_pct = int(round(100 * total_cr / max(total_cr + total_paid_input, 1)))

print(int(round(total_cost_usd * 100)))   # cents
print(last_context_tokens // 1000)        # K tokens
print(primary_model)
print(len(turns))
print(cache_hit_pct)
PY
}

# --- antipattern detection ---------------------------------------------------
#
# Scans the last ~20 assistant messages for tool-use patterns that burn
# tokens without making progress. Each detector returns a one-line reason
# string when fired; the main loop nags as soon as any fires, regardless
# of the cost threshold. Tuned to catch "we're $5 in but spending
# inefficiently" before the bill stacks up.
detect_antipatterns() {
  /usr/bin/python3 - "$transcript_path" "$session_start" <<'PY'
import json, os, re, sys
from collections import Counter
sys.path.insert(0, os.environ['THERMOSTAT_LIB_DIR'])
from _lib import in_session

path = sys.argv[1]
start_unix = int(sys.argv[2]) if len(sys.argv) > 2 else 0
if not path or not os.path.exists(path):
    sys.exit(0)

WINDOW = 30   # last N assistant messages (deduped by message.id)
tool_calls = []  # list of (tool_name, key) where key collapses identical calls
seen_msg_ids = set()   # dedupe re-appended assistant rows by message.id
with open(path, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get('type') != 'assistant':
            continue
        if not in_session(obj, start_unix):
            continue
        mid = obj.get('message', {}).get('id')
        if mid:
            if mid in seen_msg_ids:
                continue
            seen_msg_ids.add(mid)
        content = obj.get('message', {}).get('content', [])
        if not isinstance(content, list):
            continue
        for c in content:
            if not isinstance(c, dict) or c.get('type') != 'tool_use':
                continue
            name = c.get('name', '?')
            inp  = c.get('input') or {}
            if name == 'Read':
                key = ('Read', (inp.get('file_path') or '').strip())
            elif name == 'Bash':
                # Collapse on full command — re-running the same exact shell
                # invocation is the signal we want.
                key = ('Bash', (inp.get('command') or '').strip())
            elif name == 'Grep':
                key = ('Grep', (inp.get('pattern') or '') + '|' + (inp.get('path') or ''))
            elif name == 'WebFetch':
                key = ('WebFetch', (inp.get('url') or '').strip())
            elif name == 'Agent':
                key = ('Agent', (inp.get('subagent_type') or 'general-purpose'))
            elif name in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
                key = (name, (inp.get('file_path') or inp.get('notebook_path') or '').strip())
            else:
                key = (name, '')
            tool_calls.append((name, key, inp))

recent = tool_calls[-WINDOW:]
reasons = []

# 1) Same Read of the same file ≥3 times in the recent window — context
#    that's already been read is still in scope; rereading wastes input.
#    Exclude files that were also edited: re-reading after every Edit is
#    expected (the tool needs to verify the change), not a waste signal.
edited_files = {k[1] for n, k, _ in recent
                if n in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') and k[1]}
read_keys = [k for n, k, _ in recent if n == 'Read' and k[1] not in edited_files]
for key, n in Counter(read_keys).most_common(3):
    if n >= 3:
        reasons.append(f"re-Read of {key[1]!r} x{n} in last {WINDOW} tool calls")
        break

# 2) Same Bash command run ≥3 times — usually a copy-paste retry loop.
bash_keys = [k for n, k, _ in recent if n == 'Bash' and k[1]]
for key, n in Counter(bash_keys).most_common(3):
    if n >= 3:
        snippet = key[1][:80].replace('\n', ' ')
        reasons.append(f"repeated Bash {snippet!r} x{n}")
        break

# 3) Long sleeps in Bash — script-level `sleep 60+` chains. The harness
#    already blocks naked long sleeps but inline ones still slip through.
for n, k, inp in recent:
    if n != 'Bash':
        continue
    cmd = (inp.get('command') or '')
    m = re.search(r'(?<![A-Za-z_])sleep\s+(\d+)', cmd)
    if m and int(m.group(1)) >= 60:
        reasons.append(f"long inline `sleep {m.group(1)}` in a Bash call (use run_in_background instead)")
        break

# 4) Subagent over-spawn — 3+ Agent calls of the same subagent_type recent.
agent_keys = [k[1] for n, k, _ in recent if n == 'Agent']
for sa, n in Counter(agent_keys).most_common(2):
    if n >= 3:
        reasons.append(f"{n} {sa!r} subagent spawns in last {WINDOW} tool calls — consider direct tools")
        break

# 5) Exploratory grep-chain: lots of distinct Grep + Read calls in the
#    recent window suggests "feeling around" the codebase, which burns
#    input tokens fast. A single Auggie codebase-retrieval call is usually
#    cheaper and more accurate.
explor = [n for n, _, _ in recent if n in ('Grep', 'Read', 'Glob')]
if len(explor) >= 10:
    reasons.append(
        f"{len(explor)} Grep/Read/Glob calls in last {WINDOW} tool calls — "
        f"try mcp__auggie__codebase-retrieval for natural-language lookups"
    )

# 6) Same WebFetch URL hit repeatedly — almost always a "didn't read the
#    answer last time" tell.
wf_keys = [k[1] for n, k, _ in recent if n == 'WebFetch']
for u, n in Counter(wf_keys).most_common(2):
    if n >= 3:
        reasons.append(f"WebFetch on {u!r} x{n} — page content is in context already")
        break

for r in reasons:
    print(r)
PY
}

# --- rolling-window approximation (subscription quota stand-in) -------------
#
# Walks every transcript under ~/.claude/projects, tail-scans the new bytes
# since last call (index sidecar lives at ~/.claude/thermostat/window-index.json),
# and sums tokens whose timestamp falls in [now - WINDOW_SEC, now]. The number
# we print here is local math, not Anthropic's actual quota state — see the
# README "Subscription window" section for what this can and can't tell you.
window_tokens() {
  WINDOW_SEC_ARG="$WINDOW_SEC" \
  WINDOW_COUNT_CACHED_ARG="$WINDOW_COUNT_CACHED" \
  INDEX_PATH="$STATE_DIR/window-index.json" \
  /usr/bin/python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ['THERMOSTAT_LIB_DIR'])
from _lib import update_window_index, tokens_in_window, format_token_count
window_sec = int(os.environ.get('WINDOW_SEC_ARG') or 18000)
count_cached = os.environ.get('WINDOW_COUNT_CACHED_ARG', '1') == '1'
# Index keeps up to 7h of history so a 5h-or-shorter window is fully covered.
max_age = max(window_sec + 7200, 25200)
idx = update_window_index(os.environ['INDEX_PATH'], count_cached=count_cached, max_age_sec=max_age)
totals = tokens_in_window(window_sec, idx)
total = sum(totals.values())
print(total)
print(format_token_count(total))
PY
}

{ read -r session_start; read -r turn_count; read -r last_nag_turn; read -r nag_count; } < <(read_state)

# First turn: stamp session start.
if [ "$session_start" -eq 0 ]; then
  session_start="$now"
fi
turn_count=$(( turn_count + 1 ))

# Parse transcript (graceful: outputs zeros if file missing or unreadable).
{ read -r cost_cents; read -r context_k; read -r model; read -r tx_turns; read -r cache_hit_pct; } < <(parse_transcript)
# Default empty values so arithmetic comparisons below don't error.
cost_cents="${cost_cents:-0}"
context_k="${context_k:-0}"
tx_turns="${tx_turns:-0}"
cache_hit_pct="${cache_hit_pct:-0}"

# Window mode only runs when the user has set a token setpoint. The index
# scan is cheap but pointless when nothing reads its output.
window_tokens_total=0
window_tokens_display=""
if [ "$WINDOW_TOKENS_THRESH" -gt 0 ]; then
  { read -r window_tokens_total; read -r window_tokens_display; } < <(window_tokens)
  window_tokens_total="${window_tokens_total:-0}"
fi

# Check cooldown: skip if we nagged recently and haven't hit cooldown turn yet.
if [ "$last_nag_turn" -gt 0 ]; then
  turns_since_nag=$(( turn_count - last_nag_turn ))
  if [ "$turns_since_nag" -lt "$COOLDOWN_TURNS" ]; then
    write_state "$session_start" "$turn_count" "$last_nag_turn" "$nag_count"
    exit 0
  fi
fi

# --- check thresholds --------------------------------------------------------

elapsed=$(( now - session_start ))
mins=$(( elapsed / 60 ))
should_nag=0
reasons=""

# Pre-format the cost so the header can show it whether or not cost is what
# triggered the nag.
cost_display=$(COST_CENTS="${cost_cents:-0}" /usr/bin/python3 -c \
  "import os; print(f'\${int(os.environ[\"COST_CENTS\"])/100:.2f}')" 2>/dev/null || echo "\$$((${cost_cents:-0} / 100))")

# Cost: the canonical trigger. $50 default, raise via env if you want quieter.
if [ "$cost_cents" -ge "$COST_THRESH" ]; then
  should_nag=1
  reasons+="  •  estimated session cost: ${cost_display}"$'\n'
fi

# Antipattern triggers fire regardless of cost — catch waste while it's cheap.
if [ "$ANTIPATTERN_DETECT" = "1" ]; then
  while IFS= read -r ap_reason; do
    [ -z "$ap_reason" ] && continue
    should_nag=1
    reasons+="  •  antipattern: ${ap_reason}"$'\n'
  done < <(detect_antipatterns)
fi

# Opt-in triggers: each fires only when its setpoint is set to a non-zero
# value via env var. Useful for users who want a turn-cap or wall-clock
# nudge in addition to (or instead of) the cost setpoint.
if [ "$TIME_THRESH" -gt 0 ] && [ "$elapsed" -ge "$TIME_THRESH" ]; then
  should_nag=1
  reasons+="  •  session is ${mins} min old"$'\n'
fi
if [ "$TURNS_THRESH" -gt 0 ] && [ "$turn_count" -ge "$TURNS_THRESH" ]; then
  should_nag=1
  reasons+="  •  ${turn_count} turns completed this session"$'\n'
fi
if [ "$CONTEXT_THRESH_K" -gt 0 ] && [ "${context_k:-0}" -ge "$CONTEXT_THRESH_K" ]; then
  should_nag=1
  reasons+="  •  last-turn input context: ~${context_k}K tokens (each turn now costs more)"$'\n'
fi
if [ "$WINDOW_TOKENS_THRESH" -gt 0 ] && [ "$window_tokens_total" -ge "$WINDOW_TOKENS_THRESH" ]; then
  should_nag=1
  window_hours=$(( WINDOW_SEC / 3600 ))
  reasons+="  •  ${window_tokens_display} tokens used in the last ${window_hours}h (local approx; not a real quota read)"$'\n'
fi

if [ "$should_nag" -eq 0 ]; then
  write_state "$session_start" "$turn_count" "$last_nag_turn" "$nag_count"
  exit 0
fi

# --- compose nag -------------------------------------------------------------

nag_count=$(( nag_count + 1 ))
# Header packs the four signals on one line, in a stable order. The pipes
# read better than commas when scanning quickly.
header="thermostat · turn ${turn_count}"
[ "$mins" -gt 0 ] && header+=" · ${mins}m"
[ "$cost_cents" -gt 0 ] && header+=" · ${cost_display}"
[ "$context_k" -gt 0 ] && header+=" · ${context_k}K ctx"
[ "$cache_hit_pct" -gt 0 ] && header+=" · ${cache_hit_pct}% cached"
if [ "$WINDOW_TOKENS_THRESH" -gt 0 ] && [ -n "$window_tokens_display" ]; then
  window_hours=$(( WINDOW_SEC / 3600 ))
  header+=" · ${window_tokens_display} tok/${window_hours}h"
fi

# Context-sensitive suggestions: lead with what's most useful given triggers.
suggestions=""
if [ "${context_k:-0}" -ge "${CONTEXT_THRESH_K:-80}" ]; then
  suggestions+="  →  \`/compact\` — summarizes history and shrinks the context window; best option when context is large and the task is ongoing"$'\n'
  suggestions+="  →  Delegate exploratory work to a subagent (Task tool) — the subagent's tool output stays out of the main context, so reads/greps don't keep growing your bill on every subsequent turn"$'\n'
fi
case "$model" in
  claude-opus-*)
    suggestions+="  →  \`/model sonnet\` — Opus input is 5× Sonnet (\$15 vs \$3 per M tokens) and output is 5× (\$75 vs \$15); switch unless this turn really needs Opus reasoning"$'\n'
    ;;
esac
suggestions+="  →  \`/clear\` — wipe context entirely and start fresh; good when pivoting to a new task"$'\n'
suggestions+="  →  Close and reopen — lowest-cost baseline; use when this task is done or you want a clean slate"$'\n'
suggestions+="  →  Continue — if you're nearly done and want to push through"$'\n'

# One-time structural advice on the first nag of the session: most expensive
# sessions are expensive every turn because too much auto-loads into context.
if [ "$nag_count" -eq 1 ]; then
  suggestions+=""$'\n'
  suggestions+="Structural fixes worth doing once (apply between sessions, not now):"$'\n'
  suggestions+="  →  Audit \`~/.claude/rules/\` + project \`.claude/rules/\` — convert big reference docs to on-demand skills (\`~/.claude/skills/\`) so they only load when invoked. Anthropic guidance: rules trigger on file patterns, skills trigger on intent"$'\n'
  suggestions+="  →  Narrow rule globs to the directories that actually need them (e.g. \`**/{routes,api}/**\` instead of \`**/*.ts\`) — fewer rules auto-load on each turn"$'\n'
fi

msg="🌡  ${header}"$'\n'
msg+="${reasons}"$'\n'
msg+="Tell the user and ask them what they'd like to do:"$'\n'
msg+="${suggestions}"
msg+="Acknowledge their choice and proceed. Don't fire again unless setpoints are crossed again."

write_state "$session_start" "$turn_count" "$turn_count" "$nag_count"

printf '%s\n' "$msg" 1>&2
exit 2
