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
#     NOTE: subscription users (Max / Pro / Team / Enterprise) are NOT billed
#     per-token — their quota is tracked in tokens, not dollars. The dollar
#     figure here is an API-equivalent estimate, not real charges. Set
#     CLAUDE_THERMOSTAT_COST_CENTS=0 to disable the dollar trigger and use
#     CLAUDE_THERMOSTAT_WINDOW_TOKENS as the primary setpoint instead.
#   CLAUDE_THERMOSTAT_CONTEXT_K       0     0 = disabled
#   CLAUDE_THERMOSTAT_CACHE_HIT_MIN   0     0 = disabled; fire when session cache hit % drops below this
#   CLAUDE_THERMOSTAT_COOLDOWN_TURNS  10    turns between re-fires after first
#   CLAUDE_THERMOSTAT_COST_MODE       api   'api' = include cache_read at 0.1x
#                                            input (matches published Anthropic
#                                            pricing). 'claude-code' = exclude
#                                            cache_read (matches the cost
#                                            Claude Code displays for users on
#                                            Max / Pro / Team / Enterprise).
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
# State lives at ~/.claude/thermostat/<session_id>.json. Since the incremental
# rework, the state file also carries a `tx` block (transcript byte offset,
# running per-model token totals, rolling tool-call window) so each Stop only
# parses the lines appended since the previous one — the hook's cost no longer
# grows with session length, and the whole analysis is one python process.

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
CACHE_HIT_THRESH="${CLAUDE_THERMOSTAT_CACHE_HIT_MIN:-0}"      # 0 disables
COOLDOWN_TURNS="${CLAUDE_THERMOSTAT_COOLDOWN_TURNS:-10}"
# Antipattern detection: fire the moment recurring waste is visible, even
# if the dollar setpoint isn't hit yet.
ANTIPATTERN_DETECT="${CLAUDE_THERMOSTAT_ANTIPATTERNS:-1}"     # 1 enables
# 'api' bills cache_read at the published 0.1x input rate. 'claude-code'
# excludes cache_read entirely, matching Claude Code's own cost number for
# subscription / Team / Enterprise plans.
COST_MODE="${CLAUDE_THERMOSTAT_COST_MODE:-api}"
# Subscription-window approximation. Off by default; setpoint of 0 hides it
# from the header so users on API billing don't see noise they don't need.
WINDOW_SEC="${CLAUDE_THERMOSTAT_WINDOW_SEC:-18000}"           # 5h
WINDOW_TOKENS_THRESH="${CLAUDE_THERMOSTAT_WINDOW_TOKENS:-0}"  # 0 disables
WINDOW_COUNT_CACHED="${CLAUDE_THERMOSTAT_WINDOW_COUNT_CACHED:-1}"
# Auto-delegate: when context >= this threshold (K tokens), the nag instructs
# Claude to automatically route the next exploration task to a subagent instead
# of just offering it as an option. 0 disables (soft suggestion only).
# CLAUDE_THERMOSTAT_SUBAGENT_MODEL: optional model ID passed to the subagent
# instruction (e.g. claude-haiku-4-5-20251001). Empty = no model hint.
AUTODELEGATE_K="${CLAUDE_THERMOSTAT_AUTODELEGATE_K:-0}"
SUBAGENT_MODEL="${CLAUDE_THERMOSTAT_SUBAGENT_MODEL:-}"

input="$(cat)"
now=$(date +%s)

# --- single-pass incremental analysis ----------------------------------------
#
# One python process does everything the hook needs per Stop: parse the hook
# JSON, load state, tail-scan only the transcript bytes appended since the
# last invocation (offset + running totals live in the state file's `tx`
# block), compute cost / context / cache stats, run the antipattern detectors
# over a persisted rolling window of the last 30 tool calls, save state
# atomically, and print everything the shell needs.
#
# Output protocol: 15 fixed lines, then zero or more antipattern reason lines.
#   1 session_id   2 stop_hook_active(0/1)   3 session_start   4 turn_count
#   5 last_nag_turn   6 nag_count   7 cost_cents   8 context_k   9 model
#   10 tx_turns   11 cache_hit_pct   12 last_turn_cache_hit   13 cost_display
#   14 ac_thresh   15 show_ac
#
# On truncation/rotation (file shrank) the tx block resets and the transcript
# is re-scanned from byte 0, so the totals self-heal. If python dies, output
# is empty and the shell exits 0 — fail open, never block a turn.
#
# Defined as a function so the heredoc is parsed as a plain command — bash 3.2
# (macOS default) mis-parses backticks inside heredocs wrapped directly in $( ).
analyze() {
  HOOK_JSON="$input" STATE_DIR_ARG="$STATE_DIR" \
  COST_MODE_ARG="$COST_MODE" NOW_ARG="$now" /usr/bin/python3 - <<'PY' 2>/dev/null
import json, os, re, sys, time
from collections import Counter
sys.path.insert(0, os.environ['THERMOSTAT_LIB_DIR'])
from _lib import is_real_user, in_session, lookup_pricing

SLEEP_RE = re.compile(r'(?<![A-Za-z_])sleep\s+(\d+)')
WINDOW = 30      # rolling tool-call / message window for antipattern detection
SEEN_CAP = 500   # recent message.ids kept for dedupe (re-appends are adjacent)

def tool_key(name, inp):
    if name == 'Read': return (inp.get('file_path') or '').strip()
    if name == 'Bash': return (inp.get('command') or '').strip()
    if name == 'Grep': return (inp.get('pattern') or '') + '|' + (inp.get('path') or '')
    if name == 'WebFetch': return (inp.get('url') or '').strip()
    if name == 'Agent': return inp.get('subagent_type') or 'general-purpose'
    if name in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
        return (inp.get('file_path') or inp.get('notebook_path') or '').strip()
    return ''

def emit(session_id='', active=1, ss=0, tc=0, lnt=0, nc=0, cost=0, ctx=0,
         model='unknown', turns=0, hit=0, lt_hit=0, disp='$0.00',
         ac='default', show_ac=1, reasons=()):
    for v in (session_id, active, ss, tc, lnt, nc, cost, ctx, model,
              turns, hit, lt_hit, disp, ac, show_ac):
        print(v)
    for r in reasons:
        print(r)

try:
    hook = json.loads(os.environ.get('HOOK_JSON') or '{}')
except Exception:
    hook = {}
session_id = str(hook.get('session_id') or '')
active = 1 if str(hook.get('stop_hook_active')).lower() == 'true' else 0
tpath = hook.get('transcript_path') or ''
NOW = int(os.environ.get('NOW_ARG') or time.time())
cost_mode = os.environ.get('COST_MODE_ARG') or 'api'
state_dir = os.environ['STATE_DIR_ARG']

if not session_id or active:
    emit(session_id=session_id, active=active)
    sys.exit(0)

state_file = os.path.join(state_dir, session_id + '.json')
try:
    st = json.load(open(state_file)) if os.path.exists(state_file) else {}
except Exception:
    st = {}
ss  = int(st.get('session_start') or 0) or NOW
tc  = int(st.get('turn_count') or 0) + 1
lnt = int(st.get('last_nag_turn') or 0)
nc  = int(st.get('nag_count') or 0)
tx  = st.get('tx') if isinstance(st.get('tx'), dict) else {}

# --- incremental transcript scan ---
size = -1
if tpath:
    try:
        size = os.path.getsize(tpath)
    except OSError:
        size = -1
if size >= 0:
    if size < int(tx.get('size') or 0):
        tx = {}                       # truncated / rotated: full re-scan
    offset = int(tx.get('offset') or 0)
    if offset > size:
        offset, tx = 0, {}
    tok    = tx.get('tok') or {}      # model -> [in, cache_write, cache_read, out]
    seen   = list(tx.get('seen') or [])
    seen_set = set(seen)
    calls  = list(tx.get('calls') or [])   # [name, key, max_sleep_secs]
    msgs   = list(tx.get('msgs') or [])    # [output_tokens, has_script_call]
    closed = int(tx.get('closed_turns') or 0)
    cur_has_usage = bool(tx.get('cur_has_usage'))
    cur_model = tx.get('cur_model') or None
    cur_cr    = int(tx.get('cur_cr') or 0)
    cur_paid  = int(tx.get('cur_paid') or 0)
    last_ctx  = int(tx.get('last_ctx') or 0)
    consumed = 0
    tail = b''
    try:
        with open(tpath, 'rb') as f:
            f.seek(offset)
            tail = f.read()
        nl = tail.rfind(b'\n')
        if nl < 0:            # file ends mid-line: leave fragment for next pass
            tail = b''
        else:
            consumed = nl + 1
            tail = tail[:consumed]
    except OSError:
        tail = b''
    for raw in tail.splitlines():
        if not raw.strip():
            continue
        try:
            obj = json.loads(raw.decode('utf-8', errors='replace'))
        except Exception:
            continue
        t = obj.get('type')
        if t == 'user':
            if not in_session(obj, ss):
                continue
            if is_real_user(obj):
                if cur_has_usage:
                    closed += 1
                cur_has_usage = False
                cur_model = None
                cur_cr = cur_paid = 0
        elif t == 'assistant':
            if not in_session(obj, ss):
                continue
            msg = obj.get('message') or {}
            mid = msg.get('id')
            if mid:
                if mid in seen_set:   # re-appended row (tool round-trip): billed already
                    continue
                seen_set.add(mid)
                seen.append(mid)
            usage = msg.get('usage')
            m = msg.get('model')
            if usage:
                # Bill the whole turn at the turn's first non-synthetic model.
                if cur_model is None and m and m != '<synthetic>':
                    cur_model = m
                bill_model = cur_model or (m if m and m != '<synthetic>' else None) or 'unknown'
                row = tok.setdefault(bill_model, [0, 0, 0, 0])
                i  = usage.get('input_tokens', 0) or 0
                cw = usage.get('cache_creation_input_tokens', 0) or 0
                cr = usage.get('cache_read_input_tokens', 0) or 0
                o  = usage.get('output_tokens', 0) or 0
                row[0] += i; row[1] += cw; row[2] += cr; row[3] += o
                cur_has_usage = True
                cur_cr += cr
                cur_paid += i + cw
                last_ctx = i + cw + cr
            content = msg.get('content', [])
            if isinstance(content, list):
                has_script = False
                for c in content:
                    if not isinstance(c, dict) or c.get('type') != 'tool_use':
                        continue
                    name = c.get('name', '?')
                    inp = c.get('input') or {}
                    if name in ('Bash', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
                        has_script = True
                    slp = 0
                    if name == 'Bash':
                        mt = SLEEP_RE.search(inp.get('command') or '')
                        if mt:
                            slp = int(mt.group(1))
                    calls.append([name, tool_key(name, inp), slp])
                msgs.append([(usage or {}).get('output_tokens', 0) or 0, has_script])
    tx = {
        'offset': offset + consumed, 'size': size,
        'tok': tok, 'seen': seen[-SEEN_CAP:],
        'calls': calls[-WINDOW:], 'msgs': msgs[-WINDOW:],
        'closed_turns': closed, 'cur_has_usage': cur_has_usage,
        'cur_model': cur_model, 'cur_cr': cur_cr, 'cur_paid': cur_paid,
        'last_ctx': last_ctx,
    }

# --- save state (atomic) ---
st_out = {
    'session_start': ss, 'turn_count': tc,
    'last_nag_turn': lnt, 'nag_count': nc,
    'nag_history': st.get('nag_history', []),
    'tx': tx,
}
try:
    tmp = state_file + '.tmp'
    json.dump(st_out, open(tmp, 'w'))
    os.replace(tmp, state_file)
except OSError:
    pass

# --- derive outputs ---
if size < 0:
    # Transcript missing/unreadable: report zeros (matches historical behavior)
    # but keep whatever tx we had so totals survive a transient glitch.
    emit(session_id, 0, ss, tc, lnt, nc)
    sys.exit(0)

cost_by_model = {}
total_usd = 0.0
total_cr = total_paid = 0
for mdl, (i, cw, cr, o) in (tx.get('tok') or {}).items():
    p = lookup_pricing(mdl)
    cr_cost = cr * p[2] if cost_mode == 'api' else 0
    c = (i * p[0] + cw * p[1] + cr_cost + o * p[3]) / 1_000_000
    cost_by_model[mdl] = c
    total_usd += c
    total_cr += cr
    total_paid += i + cw
cost_cents = int(round(total_usd * 100))
context_k = int(tx.get('last_ctx') or 0) // 1000
primary = max(cost_by_model, key=cost_by_model.get) if cost_by_model else 'unknown'
tx_turns = int(tx.get('closed_turns') or 0) + (1 if tx.get('cur_has_usage') else 0)
hit = int(round(100 * total_cr / max(total_cr + total_paid, 1)))
ccr, cpaid = int(tx.get('cur_cr') or 0), int(tx.get('cur_paid') or 0)
lt_hit = int(round(100 * ccr / max(ccr + cpaid, 1)))

# --- antipattern detection over the persisted rolling window ---
# Same detectors as the historical full-scan version; the window now lives in
# state so each Stop only appends the new turn's calls.
reasons = []
recent = [(r[0], r[1], r[2]) for r in (tx.get('calls') or [])]
msg_stats = [(r[0], r[1]) for r in (tx.get('msgs') or [])]

# 1) Same Read of the same file ≥3 times in the recent window — context
#    that's already been read is still in scope; rereading wastes input.
#    Exclude files that were also edited: re-reading after every Edit is
#    expected (the tool needs to verify the change), not a waste signal.
edited_files = {k for n, k, s in recent
                if n in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') and k}
read_keys = [k for n, k, s in recent if n == 'Read' and k not in edited_files]
for key, cnt in Counter(read_keys).most_common(3):
    if cnt >= 3:
        reasons.append(f"re-Read of {key!r} x{cnt} in last {WINDOW} tool calls")
        break

# 2) Same Bash command run ≥3 times — usually a copy-paste retry loop.
bash_keys = [k for n, k, s in recent if n == 'Bash' and k]
for key, cnt in Counter(bash_keys).most_common(3):
    if cnt >= 3:
        snippet = key[:80].replace('\n', ' ')
        reasons.append(f"repeated Bash {snippet!r} x{cnt}")
        break

# 3) Long sleeps in Bash — script-level `sleep 60+` chains. The harness
#    already blocks naked long sleeps but inline ones still slip through.
for n, k, s in recent:
    if n == 'Bash' and s >= 60:
        reasons.append(f"long inline `sleep {s}` in a Bash call (use run_in_background instead)")
        break

# 4) Subagent over-spawn — 3+ Agent calls of the same subagent_type recent.
agent_keys = [k for n, k, s in recent if n == 'Agent']
for sa, cnt in Counter(agent_keys).most_common(2):
    if cnt >= 3:
        reasons.append(f"{cnt} {sa!r} subagent spawns in last {WINDOW} tool calls — consider direct tools")
        break

# 5) Exploratory grep-chain: lots of distinct Grep + Read calls in the
#    recent window suggests "feeling around" the codebase, which burns
#    input tokens fast. A single Auggie codebase-retrieval call is usually
#    cheaper and more accurate.
explor = [n for n, k, s in recent if n in ('Grep', 'Read', 'Glob')]
if len(explor) >= 6:
    reasons.append(
        f"{len(explor)} Grep/Read/Glob calls in last {WINDOW} tool calls — "
        f"try mcp__auggie__codebase-retrieval for natural-language lookups"
    )

# 6) Same WebFetch URL hit repeatedly — almost always a "didn't read the
#    answer last time" tell.
wf_keys = [k for n, k, s in recent if n == 'WebFetch']
for u, cnt in Counter(wf_keys).most_common(2):
    if cnt >= 3:
        reasons.append(f"WebFetch on {u!r} x{cnt} — page content is in context already")
        break

# 7) MCP result accumulation — each call's response stays in context for
#    the rest of the session. When a server is hit repeatedly, the payloads
#    pile up fast. /compact is the only flush mechanism mid-session.
mcp_by_server = Counter()
for n, k, s in recent:
    if n.startswith('mcp__'):
        parts = n.split('__')
        if len(parts) >= 2 and parts[1]:
            mcp_by_server[parts[1]] += 1
fired_mcp = False
for server, cnt in mcp_by_server.most_common(2):
    if cnt >= 5:
        reasons.append(
            f"{cnt} '{server}' MCP calls in last {WINDOW} tool calls — "
            f"each response stays in context; /compact to flush before continuing"
        )
        fired_mcp = True
        break
total_mcp = sum(mcp_by_server.values())
if not fired_mcp and total_mcp >= 10:
    srv_list = ', '.join(f"{s2} ({c2}x)" for s2, c2 in mcp_by_server.most_common(3))
    reasons.append(
        f"{total_mcp} MCP calls in last {WINDOW} tool calls ({srv_list}) — "
        f"responses accumulate in context; /compact to flush before continuing"
    )

# 8) High-output turns with no Bash/Write calls in the recent window —
#    model grinding through deterministic work (data transforms, arithmetic,
#    row-by-row reformatting) instead of scripting it. A single tested script
#    does the same work faster, cheaper, and reproducibly.
OUTPUT_THRESH = 3000
high_out_no_script = [o for o, has_s in msg_stats if o >= OUTPUT_THRESH and not has_s]
if len(high_out_no_script) >= 2:
    total_out_k = sum(high_out_no_script) // 1000
    reasons.append(
        f"{len(high_out_no_script)} high-output turns (≥{OUTPUT_THRESH} tokens, no Bash/Write) "
        f"in last {WINDOW} messages ({total_out_k}K output total) — model may be doing "
        f"deterministic work inline (data transforms, formatting, arithmetic); "
        f"use the deterministic-toolkit skill to script it instead"
    )

# --- autoCompactThreshold hint (read once here; saves two shell spawns) ---
ac = 'default'
show_ac = 1
try:
    sset = json.load(open(os.path.expanduser('~/.claude/settings.json')))
    v = sset.get('autoCompactThreshold')
    if v is not None:
        ac = f'{float(v):.2f}'
        show_ac = 1 if float(v) > 0.75 else 0
except Exception:
    pass

emit(session_id, 0, ss, tc, lnt, nc, cost_cents, context_k, primary,
     tx_turns, hit, lt_hit, f'${cost_cents / 100:.2f}', ac, show_ac, reasons)
PY
}

analysis_out="$(analyze)"
[ -z "$analysis_out" ] && exit 0

{
  read -r session_id
  read -r stop_hook_active
  read -r session_start
  read -r turn_count
  read -r last_nag_turn
  read -r nag_count
  read -r cost_cents
  read -r context_k
  read -r model
  read -r tx_turns
  read -r cache_hit_pct
  read -r last_turn_cache_hit
  read -r cost_display
  read -r ac_thresh
  read -r show_ac
  ap_reasons="$(cat)"
} <<< "$analysis_out"

[ -z "$session_id" ] && exit 0
# Stop hooks re-activate Claude when exiting 2. stop_hook_active is set on
# that re-invocation so we don't loop.
[ "$stop_hook_active" = "1" ] && exit 0

state_file="$STATE_DIR/${session_id}.json"

# Default empty values so arithmetic comparisons below don't error.
cost_cents="${cost_cents:-0}"
context_k="${context_k:-0}"
tx_turns="${tx_turns:-0}"
cache_hit_pct="${cache_hit_pct:-0}"
last_turn_cache_hit="${last_turn_cache_hit:-0}"

# Appends one nag event to nag_history and re-arms the cooldown. Called only
# when the alert actually fires; preserves the tx block and all other state.
record_nag() {
  TURN="$1" COST="$2" CTX_K="$3" TRIGGERS="$4" NAGC="$5" /usr/bin/python3 - "$state_file" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    d = json.load(open(p)) if os.path.exists(p) else {}
except Exception:
    d = {}
turn = int(os.environ['TURN'])
d['last_nag_turn'] = turn
d['nag_count'] = int(os.environ['NAGC'])
hist = d.get('nag_history', [])
hist.append({
    'turn':       turn,
    'cost_cents': int(os.environ['COST']),
    'context_k':  int(os.environ['CTX_K']),
    'triggers':   [t.strip() for t in os.environ['TRIGGERS'].split(',') if t.strip()],
})
d['nag_history'] = hist
try:
    tmp = p + '.tmp'
    json.dump(d, open(tmp, 'w'))
    os.replace(tmp, p)
except OSError:
    pass
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

# Window mode only runs when the user has set a token setpoint. The index
# scan is cheap but pointless when nothing reads its output.
window_tokens_total=0
window_tokens_display=""
if [ "$WINDOW_TOKENS_THRESH" -gt 0 ]; then
  { read -r window_tokens_total; read -r window_tokens_display; } < <(window_tokens)
  window_tokens_total="${window_tokens_total:-0}"
fi

# Check cooldown: skip if we nagged recently and haven't hit cooldown turn yet.
# State (turn count, tx block) was already saved by the analysis pass.
if [ "$last_nag_turn" -gt 0 ]; then
  turns_since_nag=$(( turn_count - last_nag_turn ))
  if [ "$turns_since_nag" -lt "$COOLDOWN_TURNS" ]; then
    exit 0
  fi
fi

# --- check thresholds --------------------------------------------------------

elapsed=$(( now - session_start ))
mins=$(( elapsed / 60 ))
should_nag=0
reasons=""
trigger_types=""   # comma-separated: cost,antipattern,time,turns,context,cache_hit,cache_drop,window

# Cost: the canonical trigger. $50 default, raise via env if you want quieter.
if [ "$cost_cents" -ge "$COST_THRESH" ]; then
  should_nag=1
  trigger_types+="cost,"
  reasons+="  •  estimated session cost: ${cost_display}"$'\n'
fi

# Antipattern triggers fire regardless of cost — catch waste while it's cheap.
if [ "$ANTIPATTERN_DETECT" = "1" ] && [ -n "$ap_reasons" ]; then
  while IFS= read -r ap_reason; do
    [ -z "$ap_reason" ] && continue
    should_nag=1
    trigger_types+="antipattern,"
    reasons+="  •  antipattern: ${ap_reason}"$'\n'
  done <<< "$ap_reasons"
fi

# Opt-in triggers: each fires only when its setpoint is set to a non-zero
# value via env var. Useful for users who want a turn-cap or wall-clock
# nudge in addition to (or instead of) the cost setpoint.
if [ "$TIME_THRESH" -gt 0 ] && [ "$elapsed" -ge "$TIME_THRESH" ]; then
  should_nag=1
  trigger_types+="time,"
  reasons+="  •  session is ${mins} min old"$'\n'
fi
if [ "$TURNS_THRESH" -gt 0 ] && [ "$turn_count" -ge "$TURNS_THRESH" ]; then
  should_nag=1
  trigger_types+="turns,"
  reasons+="  •  ${turn_count} turns completed this session"$'\n'
fi
if [ "$CONTEXT_THRESH_K" -gt 0 ] && [ "${context_k:-0}" -ge "$CONTEXT_THRESH_K" ]; then
  should_nag=1
  trigger_types+="context,"
  reasons+="  •  last-turn input context: ~${context_k}K tokens — delegate new exploration to a subagent; each turn costs more as context grows"$'\n'
fi
# Cache hit rate: opt-in setpoint; fire when session average drops below threshold.
if [ "$CACHE_HIT_THRESH" -gt 0 ] && [ "$tx_turns" -ge 3 ] && [ "${cache_hit_pct:-0}" -lt "$CACHE_HIT_THRESH" ]; then
  should_nag=1
  trigger_types+="cache_hit,"
  reasons+="  •  session cache hit rate: ${cache_hit_pct}% — below the ${CACHE_HIT_THRESH}% setpoint; most input is paying full price each turn"$'\n'
fi
# Per-turn cache drop: always-on, no setpoint needed. A 30+ point drop on the
# most recent turn means something reshuffled the context mid-session.
if [ "$tx_turns" -gt 3 ] && [ "${cache_hit_pct:-0}" -gt 50 ]; then
  drop=$(( ${cache_hit_pct:-0} - ${last_turn_cache_hit:-0} ))
  if [ "$drop" -ge 30 ]; then
    should_nag=1
    trigger_types+="cache_drop,"
    reasons+="  •  cache dropped ${drop}pp this turn (session avg ${cache_hit_pct}% → last turn ${last_turn_cache_hit}%) — context was reshuffled; likely: model switch, new large file auto-loaded, or /compact"$'\n'
  fi
fi
if [ "$WINDOW_TOKENS_THRESH" -gt 0 ] && [ "$window_tokens_total" -ge "$WINDOW_TOKENS_THRESH" ]; then
  should_nag=1
  trigger_types+="window,"
  window_hours=$(( WINDOW_SEC / 3600 ))
  reasons+="  •  ${window_tokens_display} tokens used in the last ${window_hours}h (local approx; not a real quota read)"$'\n'
fi

if [ "$should_nag" -eq 0 ]; then
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

# Build options list for ask_followup_question.
# /compact and subagent are shown when context is non-trivial (context_k > 0
# when CONTEXT_THRESH_K=0, meaning always — same gate as before).
options=""
if [ "${context_k:-0}" -ge "${CONTEXT_THRESH_K:-0}" ]; then
  options+='"/compact — shrink context (best when task is ongoing)"'$'\n'
fi
if [ "${context_k:-0}" -ge 50 ]; then
  if [ "$AUTODELEGATE_K" -gt 0 ] && [ "${context_k:-0}" -ge "$AUTODELEGATE_K" ]; then
    # Above the auto-delegate threshold: list it first and mark it as recommended.
    options+='"Delegate to a subagent (recommended — context above auto-delegate threshold)"'$'\n'
  else
    options+='"Delegate to a subagent — keep Read/Bash/Grep out of main context; cheaper turns"'$'\n'
  fi
fi
case "$model" in
  claude-opus-*)
    options+='"/model sonnet — ~1.7× cheaper; switch for routine turns"'$'\n'
    ;;
  claude-fable-*|claude-mythos-*)
    options+='"/model sonnet — ~3.3× cheaper; switch for routine turns"'$'\n'
    ;;
esac
# Auto-compact threshold: offer when context is substantial and the current
# threshold leaves room to lower it (at default ~0.90, or explicitly above
# 0.75). ac_thresh/show_ac come from the analysis pass.
if [ "${context_k:-0}" -ge 50 ] && [ "${show_ac:-0}" = "1" ]; then
  options+="\"Lower autoCompactThreshold (${ac_thresh}) → 0.70 in ~/.claude/settings.json — auto-compact fires at 70% context fill\""$'\n'
fi
options+='"/clear — fresh start (best when pivoting tasks)"'$'\n'
options+='"Continue"'$'\n'

# Structural note shown once after the user responds on the first nag.
structural_note=""
if [ "$nag_count" -eq 1 ]; then
  structural_note="After the user responds, add one brief note: audit \`~/.claude/rules/\` for large docs that could be skills (\`~/.claude/skills/\`), and narrow rule globs to directories that need them."
fi

# Auto-delegate directive: when context is above the threshold, instruct Claude
# to automatically route the next exploration task to a subagent. This fires
# regardless of what triggered the nag — it's additive context hygiene advice.
autodelegate_directive=""
if [ "$AUTODELEGATE_K" -gt 0 ] && [ "${context_k:-0}" -ge "$AUTODELEGATE_K" ] && [ "${context_k:-0}" -ge 50 ]; then
  autodelegate_directive="IMPORTANT: Context is at ${context_k}K tokens (above the ${AUTODELEGATE_K}K auto-delegate threshold). After the user responds, automatically route the next exploration task (any Read/Bash/Grep/search work) to a subagent — do not run it in the main thread."
  if [ -n "$SUBAGENT_MODEL" ]; then
    autodelegate_directive+=" Use model '${SUBAGENT_MODEL}' when spawning the subagent."
  fi
fi

msg="🌡  ${header}"$'\n'
msg+="${reasons}"$'\n'
msg+="Present this to the user using the ask_followup_question tool — call it directly, do not narrate first."$'\n'
msg+=$'\n'
msg+="Options:"$'\n'
msg+="${options}"
if [ -n "$structural_note" ]; then
  msg+=$'\n'
  msg+="${structural_note}"$'\n'
fi
if [ -n "$autodelegate_directive" ]; then
  msg+=$'\n'
  msg+="${autodelegate_directive}"$'\n'
fi
msg+=$'\n'
msg+="After the user responds, execute their choice. Don't fire again unless setpoints are crossed again."

record_nag "$turn_count" "${cost_cents:-0}" "${context_k:-0}" "$trigger_types" "$nag_count"

printf '%s\n' "$msg" 1>&2
exit 2
