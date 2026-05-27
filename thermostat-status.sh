#!/usr/bin/env bash
# thermostat-status: on-demand session status query.
#
# Finds the most recently active session and prints cost, cache hit rate,
# turn count, context size, and a flag if antipatterns are present.
# Purely informational — no setpoints, no alerts, no exit 2.
#
# Intended for use via the /thermostat Claude Code skill, but works fine
# from a terminal too:
#   ~/.claude/thermostat/status
#
# Uses the same _lib.py and config.env as the main hook.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export THERMOSTAT_LIB_DIR="$SCRIPT_DIR"

STATE_DIR="$HOME/.claude/thermostat"

CONFIG_FILE="${CLAUDE_THERMOSTAT_CONFIG:-$STATE_DIR/config.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi
COST_MODE="${CLAUDE_THERMOSTAT_COST_MODE:-api}"

/usr/bin/python3 - "$STATE_DIR" "$COST_MODE" <<'PY'
import glob, json, os, re, sys
from collections import Counter
from datetime import datetime

sys.path.insert(0, os.environ['THERMOSTAT_LIB_DIR'])
from _lib import is_real_user, in_session, turn_cost_usd, dedupe_turn, format_token_count

state_dir = sys.argv[1]
cost_mode = sys.argv[2] if len(sys.argv) > 2 else 'api'

# UUID-shaped filenames only — skip config.env and window-index.json.
UUID_RE = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$')
state_files = [
    p for p in glob.glob(os.path.join(state_dir, '*.json'))
    if UUID_RE.match(os.path.basename(p))
]
if not state_files:
    print("No active session state found in ~/.claude/thermostat/")
    sys.exit(0)

state_files.sort(key=os.path.getmtime, reverse=True)
state_path = state_files[0]
session_id = os.path.basename(state_path).replace('.json', '')

try:
    with open(state_path) as f:
        state = json.load(f)
except Exception:
    state = {}

session_start = state.get('session_start', 0)
turn_count    = state.get('turn_count', 0)
last_nag_turn = state.get('last_nag_turn', 0)
nag_count     = state.get('nag_count', 0)

# Locate transcript.
transcripts = glob.glob(os.path.expanduser(f'~/.claude/projects/*/{session_id}.jsonl'))
transcript_path = transcripts[0] if transcripts else None

if not transcript_path or not os.path.exists(transcript_path):
    print(f"thermostat status · session {session_id[:8]}")
    print()
    print(f"  Turns:  {turn_count}")
    print("  (transcript not found — cost data unavailable)")
    sys.exit(0)

# Parse transcript using the same logic as the main hook.
turns = []
current = []
model_per_turn = []
current_model = None

with open(transcript_path, encoding='utf-8', errors='replace') as f:
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
            if not in_session(obj, session_start):
                continue
            if is_real_user(obj):
                if current:
                    turns.append(current)
                    model_per_turn.append(current_model or 'unknown')
                    current = []
                    current_model = None
        elif t == 'assistant':
            if not in_session(obj, session_start):
                continue
            msg = obj.get('message', {})
            usage = msg.get('usage')
            m = msg.get('model')
            if m and not current_model and m != '<synthetic>':
                current_model = m
            if usage:
                current.append((msg.get('id'), usage))

if current:
    turns.append(current)
    model_per_turn.append(current_model or 'unknown')

total_usd = 0.0
total_in = total_cw = total_cr = total_out = 0
model_usd = Counter()

for turn, model in zip(turns, model_per_turn):
    if not turn:
        continue
    cost, inp, cw, cr, out = turn_cost_usd(turn, model, mode=cost_mode)
    total_usd += cost
    model_usd[model] += cost
    total_in += inp
    total_cw += cw
    total_cr += cr
    total_out += out

last_ctx_k = 0
last_turn_cache_hit = 0
if turns and turns[-1]:
    usages = dedupe_turn(turns[-1])
    if usages:
        last_u = usages[-1]
        last_ctx = (last_u.get('input_tokens', 0)
                    + last_u.get('cache_creation_input_tokens', 0)
                    + last_u.get('cache_read_input_tokens', 0))
        last_ctx_k = last_ctx // 1000
        lt_cr   = sum(u.get('cache_read_input_tokens', 0) for u in usages)
        lt_paid = (sum(u.get('input_tokens', 0) for u in usages)
                   + sum(u.get('cache_creation_input_tokens', 0) for u in usages))
        last_turn_cache_hit = int(round(100 * lt_cr / max(lt_cr + lt_paid, 1)))

inp_paid = total_in + total_cw
cache_hit = int(round(100 * total_cr / max(total_cr + inp_paid, 1)))

age_min = 0
if session_start:
    age_min = int((datetime.now().timestamp() - session_start) / 60)

primary_model = (model_usd.most_common(1)[0][0] if model_usd else 'unknown').replace('claude-', '')
mode_label = "API-billed" if cost_mode == 'api' else "subscription-estimated"

# Cache drop signal.
drop_note = ''
if len(turns) > 3 and cache_hit > 50:
    drop = cache_hit - last_turn_cache_hit
    if drop >= 30:
        drop_note = f'  ⚠  cache dropped {drop}pp last turn ({cache_hit}% avg → {last_turn_cache_hit}% last)'

print(f"thermostat status · session {session_id[:8]}")
print()
print(f"  Turns:     {len(turns)}")
print(f"  Age:       {age_min} min")
print(f"  Cost:      ${total_usd:.2f}  ({mode_label})")
print(f"  Context:   {last_ctx_k}K tokens  (last turn)")
print(f"  Cache hit: {cache_hit}%{(' session avg, ' + str(last_turn_cache_hit) + '% last turn') if len(turns) > 1 else ''}")
print(f"  Model:     {primary_model}")
if nag_count > 0:
    print(f"  Alerts:    {nag_count} fired  (last at turn {last_nag_turn})")
print()
print(f"  Tokens:    in={format_token_count(total_in)}  cw={format_token_count(total_cw)}  cr={format_token_count(total_cr)}  out={format_token_count(total_out)}")
if drop_note:
    print(drop_note)
PY
