#!/usr/bin/env bash
# cooldown-report: post-session cost-reduction post-mortem hook.
#
# Fires on SessionEnd (when the user quits / clears / logs out). Parses the
# full transcript and writes a cost-reduction post-mortem to
#   ~/.claude/thermostat/reports/<session_id>.md
# plus a one-line entry to
#   ~/.claude/thermostat/reports.log
#
# The goal: tell the user what would have made this session cheaper next
# time — skills they could install, prompt patterns to try, model choices.
#
# Wire-up (~/.claude/settings.json):
#   "SessionEnd": [{ "hooks": [{ "type": "command",
#                  "command": "/abs/path/to/claude-thermostat/cooldown-report.sh" }] }]

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export THERMOSTAT_LIB_DIR="$SCRIPT_DIR"

STATE_DIR="$HOME/.claude/thermostat"
REPORT_DIR="$STATE_DIR/reports"
LOG="$STATE_DIR/reports.log"
mkdir -p "$REPORT_DIR"

input="$(cat)"

{ read -r session_id; read -r transcript_path; read -r reason; } < <(
  printf '%s' "$input" | /usr/bin/python3 -c \
    "import json,sys; d=json.load(sys.stdin); [print(d.get(k,'')) for k in ['session_id','transcript_path','reason']]" 2>/dev/null
)
[ -z "$session_id" ] && exit 0
{ [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; } && exit 0

# Read session_start from state file so we only analyze the current session's
# turns (not prior sessions that share the same transcript file).
state_file="$STATE_DIR/${session_id}.json"
session_start=0
if [ -f "$state_file" ]; then
  session_start=$(STATE_FILE="$state_file" /usr/bin/python3 -c \
    "import json,os; d=json.load(open(os.environ['STATE_FILE'])); print(d.get('session_start',0))" 2>/dev/null || echo 0)
fi

# Use the pre-session path exported by the shell wrapper if available; this
# lets the wrapper print the exact file without any age-based guessing.
REPORT_FILE="${CLAUDE_COOLDOWN_FILE:-$REPORT_DIR/${session_id}.md}"
mkdir -p "$(dirname "$REPORT_FILE")"

/usr/bin/python3 - "$transcript_path" "$session_id" "$reason" "$REPORT_FILE" "$LOG" "$session_start" <<'PY'
import json, os, sys, re
from collections import Counter, defaultdict
from datetime import datetime

sys.path.insert(0, os.environ['THERMOSTAT_LIB_DIR'])
from _lib import is_real_user, in_session, turn_cost_usd, dedupe_turn, lookup_pricing

path, session_id, reason, report_file, log_file = sys.argv[1:6]
start_unix = int(sys.argv[6]) if len(sys.argv) > 6 else 0

# Each `current` entry is (message.id, usage_dict). Claude Code re-appends
# the same assistant message on every tool round-trip with the same msg id;
# dedupe_turn collapses those at billing time.
turns = []
current = []
model_per_turn = []
current_model = None
tool_calls = []   # (tool_name, key_str, input_dict, turn_idx)
seen_msg_ids = set()  # dedupe re-appended assistant rows for tool-call counts
user_prompts = []
first_ts = last_ts = None

def user_text(obj):
    c = obj.get('message', {}).get('content')
    if isinstance(c, str): return c
    if isinstance(c, list):
        parts = []
        for x in c:
            if isinstance(x, dict) and x.get('type') == 'text':
                parts.append(x.get('text', ''))
        return '\n'.join(parts)
    return ''

with open(path, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        ts = obj.get('timestamp', '')
        t = obj.get('type')
        if t == 'user':
            if not in_session(obj, start_unix):
                continue
            if ts:
                if not first_ts: first_ts = ts
                last_ts = ts
            if is_real_user(obj):
                txt = user_text(obj)
                if txt: user_prompts.append(txt)
                if current:
                    turns.append(current)
                    model_per_turn.append(current_model or 'unknown')
                    current = []
                    current_model = None
        elif t == 'assistant':
            if not in_session(obj, start_unix):
                continue
            if ts:
                if not first_ts: first_ts = ts
                last_ts = ts
            msg = obj.get('message', {})
            usage = msg.get('usage')
            m = msg.get('model')
            if m and not current_model and m != '<synthetic>': current_model = m
            if usage: current.append((msg.get('id'), usage))
            # Dedupe tool-use scanning by message.id: re-appended rows would
            # otherwise inflate "Read x5" counts on tool-heavy turns.
            mid = msg.get('id')
            if mid and mid in seen_msg_ids:
                continue
            if mid:
                seen_msg_ids.add(mid)
            content = msg.get('content', [])
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'tool_use':
                        name = c.get('name', '?')
                        inp = c.get('input') or {}
                        if name == 'Read':
                            key = (inp.get('file_path') or '').strip()
                        elif name in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
                            key = (inp.get('file_path') or inp.get('notebook_path') or '').strip()
                        elif name == 'Bash':
                            key = (inp.get('command') or '').strip()
                        elif name == 'Grep':
                            key = (inp.get('pattern') or '') + '|' + (inp.get('path') or '')
                        elif name == 'WebFetch':
                            key = (inp.get('url') or '').strip()
                        elif name == 'Agent':
                            key = inp.get('subagent_type') or 'general-purpose'
                        else:
                            key = ''
                        tool_calls.append((name, key, inp, len(turns)))
if current:
    turns.append(current)
    model_per_turn.append(current_model or 'unknown')

# --- cost ---
# Bill each unique Anthropic message.id once, per turn, per the turn's model.
# turn_cost_usd handles dedupe + dated model-id prefix matching.
total_usd = 0.0
per_model_usd = Counter()
total_in = total_cw = total_cr = total_out = 0
for turn, model in zip(turns, model_per_turn):
    if not turn: continue
    cost, inp, cw, cr, out = turn_cost_usd(turn, model)
    total_usd += cost
    per_model_usd[model] += cost
    total_in += inp; total_cw += cw; total_cr += cr; total_out += out

# --- duration ---
def parse_ts(ts):
    try: return datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except Exception: return None
dur_min = ''
if first_ts and last_ts:
    a, b = parse_ts(first_ts), parse_ts(last_ts)
    if a and b:
        dur_min = f"{int((b-a).total_seconds() / 60)} min"

# --- analyses ---
suggestions = []

# 1) Skill candidates: same file Read 3+ times, same WebFetch URL 2+ times,
#    same Grep pattern 3+ times — these are reference material that should
#    live in a skill (loaded once, on-demand).
read_counts = Counter(k for n, k, _, _ in tool_calls if n == 'Read' and k)
# Exclude files we also edited — Claude Code re-Reads after every Edit by
# design, so an edited file's Read count is noise, not a skill candidate.
# Skills are for reference material, not source you're modifying.
edited_files = {k for n, k, _, _ in tool_calls
                if n in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') and k}
for f, n in read_counts.most_common(8):
    if n < 3 or f in edited_files:
        continue
    suggestions.append((
        'skill',
        f"Read `{f}` {n}× — convert to a skill at `~/.claude/skills/` so it loads on-demand instead of re-reading"
    ))

wf_counts = Counter(k for n, k, _, _ in tool_calls if n == 'WebFetch' and k)
for u, n in wf_counts.most_common(5):
    if n >= 2:
        suggestions.append((
            'skill',
            f"WebFetch `{u}` {n}× — bundle the relevant excerpt into a skill so future sessions don't re-fetch"
        ))

grep_counts = Counter(k for n, k, _, _ in tool_calls if n == 'Grep' and k)
for g, n in grep_counts.most_common(3):
    if n >= 3:
        pat = g.split('|', 1)[0]
        suggestions.append((
            'skill',
            f"Grep `{pat}` {n}× — same exploration repeated; consider a skill with the answer pre-written, or mcp__auggie__codebase-retrieval"
        ))

# 2) Auggie / grep-chain
grep_read = sum(1 for n, _, _, _ in tool_calls if n in ('Grep', 'Read', 'Glob'))
total_tools = len(tool_calls) or 1
if grep_read >= 30 and grep_read / total_tools > 0.4:
    suggestions.append((
        'tool',
        f"{grep_read} Grep/Read/Glob calls ({100*grep_read//total_tools}% of all tool use) — heavy codebase exploration. Try `mcp__auggie__codebase-retrieval` for natural-language lookups; one call replaces a chain"
    ))

# 3) Bash repetition
bash_keys = Counter(k for n, k, _, _ in tool_calls if n == 'Bash' and k)
for cmd, n in bash_keys.most_common(3):
    if n >= 4:
        snippet = cmd[:80].replace('\n', ' ')
        suggestions.append((
            'prompt',
            f"Bash `{snippet}` ran {n}× — script it, alias it, or capture the output in a skill"
        ))

# 4) Model choice — Opus turns that produced trivial output are downgrade candidates.
opus_turns = [(t, m) for t, m in zip(turns, model_per_turn) if m.startswith('claude-opus')]
if opus_turns and per_model_usd:
    opus_usd = sum(c for m, c in per_model_usd.items() if m.startswith('claude-opus'))
    opus_share = opus_usd / max(total_usd, 1e-9)
    if opus_share > 0.5 and total_usd > 1.0:
        cheap_count = 0
        for t, _ in opus_turns:
            out = sum(u.get('output_tokens', 0) for _, u in t)
            if out < 500: cheap_count += 1
        if cheap_count >= 3:
            suggestions.append((
                'model',
                f"{cheap_count} Opus turn(s) produced <500 output tokens — these were small lookups/edits that Sonnet (5× cheaper) or Haiku (18× cheaper) would have handled. Use `/model sonnet` for routine work; reserve Opus for hard reasoning"
            ))

# 5) Cache hit rate — low cache_read ratio means context churn (rules
#    reshuffling, lots of /clear), each turn pays full input.
inp_paid = total_in + total_cw
if inp_paid + total_cr > 50_000:
    ratio = total_cr / max(total_cr + inp_paid, 1)
    if ratio < 0.4:
        suggestions.append((
            'context',
            f"Cache hit rate {ratio*100:.0f}% — most input was uncached (full price). Likely cause: large auto-loading rules, frequent /clear, or context shape changes mid-session. Audit `~/.claude/rules/` for big files that could be skills"
        ))

# 6) Prompt pattern — many very short user prompts in a row suggests
#    turn-based clarification chains. Opus 4.7 guidance: one well-formed
#    initial prompt outperforms many follow-ups.
short = sum(1 for p in user_prompts if len(p.strip()) < 60)
if len(user_prompts) >= 10 and short / len(user_prompts) > 0.5:
    suggestions.append((
        'prompt',
        f"{short}/{len(user_prompts)} prompts were <60 chars — lots of turn-based steering. Per Anthropic's Opus 4.7 guide, one detailed first prompt usually beats many small follow-ups and re-uses the cache better"
    ))

# 7) Subagent under-use when context grew large.
if turns and turns[-1]:
    last_usages = dedupe_turn(turns[-1])
    last_u = last_usages[-1] if last_usages else {}
    last_ctx = (last_u.get('input_tokens', 0)
                + last_u.get('cache_creation_input_tokens', 0)
                + last_u.get('cache_read_input_tokens', 0))
    agent_count = sum(1 for n, _, _, _ in tool_calls if n == 'Agent')
    if last_ctx > 100_000 and agent_count == 0 and grep_read > 15:
        suggestions.append((
            'tool',
            f"Final context was {last_ctx//1000}K tokens with no subagent use. Heavy exploration in the main thread keeps tool output in scope on every later turn — delegate to a subagent so the noise stays out"
        ))

# --- write report ---
lines = []
lines.append(f"# Cooldown report — {session_id}")
lines.append("")
lines.append(f"- **Ended:** {datetime.now().isoformat(timespec='seconds')} (reason: {reason or 'unknown'})")
lines.append(f"- **Duration:** {dur_min or 'unknown'}")
lines.append(f"- **Turns:** {len(turns)}")
lines.append(f"- **Cost:** ${total_usd:.2f}")
if per_model_usd:
    parts = ', '.join(f"{m.replace('claude-','')}=${c:.2f}" for m, c in per_model_usd.most_common() if round(c, 2) > 0)
    if parts:
        lines.append(f"- **By model:** {parts}")
lines.append(f"- **Tokens:** in={total_in:,} cache_write={total_cw:,} cache_read={total_cr:,} out={total_out:,}")
_paid = total_in + total_cw
_hit  = total_cr / max(total_cr + _paid, 1)
lines.append(f"- **Cache hit:** {_hit*100:.0f}% (higher = cheaper; <40% suggests context churn)")
lines.append("")

if suggestions:
    lines.append("## Cost-reduction suggestions for next session")
    lines.append("")
    by_kind = defaultdict(list)
    for kind, s in suggestions:
        by_kind[kind].append(s)
    titles = {
        'skill': 'New skills to consider',
        'tool':  'Better tool choices',
        'model': 'Model choice',
        'prompt':'Prompt patterns',
        'context':'Context hygiene',
    }
    for kind in ('model', 'skill', 'tool', 'context', 'prompt'):
        if kind not in by_kind: continue
        lines.append(f"### {titles[kind]}")
        for s in by_kind[kind]:
            lines.append(f"- {s}")
        lines.append("")
else:
    lines.append("## Cost-reduction suggestions")
    lines.append("")
    lines.append("_No notable inefficiencies detected — this session looked efficient._")
    lines.append("")

# Tool histogram (informational tail)
if tool_calls:
    lines.append("## Tool histogram")
    lines.append("")
    lines.append("| Tool | Calls |")
    lines.append("|---|---:|")
    for name, n in Counter(n for n, _, _, _ in tool_calls).most_common():
        lines.append(f"| {name} | {n} |")
    lines.append("")

with open(report_file, 'w') as f:
    f.write('\n'.join(lines))

# One-line log
n_sugg = len(suggestions)
log_line = f"{datetime.now().isoformat(timespec='seconds')}  {session_id[:8]}  ${total_usd:.2f}  {len(turns)}t  {n_sugg} suggestion(s)  -> {report_file}\n"
with open(log_file, 'a') as f:
    f.write(log_line)

# Print the full suggestion list to stderr so it's visible in the terminal
# as the session closes — not just the one-line pointer.
print('', file=sys.stderr)
print(f"━━━ cooldown-report ━━━  ${total_usd:.2f} · {len(turns)} turns · {dur_min or '?'} · {_hit*100:.0f}% cached", file=sys.stderr)
if per_model_usd:
    parts = ', '.join(f"{m.replace('claude-','')}=${c:.2f}" for m, c in per_model_usd.most_common() if round(c, 2) > 0)
    if parts:
        print(f"  models: {parts}", file=sys.stderr)
if suggestions:
    titles = {
        'model':  'Model choice',
        'skill':  'New skills to consider',
        'tool':   'Better tool choices',
        'context':'Context hygiene',
        'prompt': 'Prompt patterns',
    }
    by_kind = defaultdict(list)
    for kind, s in suggestions:
        by_kind[kind].append(s)
    for kind in ('model', 'skill', 'tool', 'context', 'prompt'):
        if kind not in by_kind: continue
        print(f"\n  {titles[kind]}:", file=sys.stderr)
        for s in by_kind[kind]:
            # wrap-aware indent for readability
            print(f"    • {s}", file=sys.stderr)
else:
    print("  No notable inefficiencies detected.", file=sys.stderr)
print(f"\n  Full report: {report_file}", file=sys.stderr)
print('━' * 60, file=sys.stderr)
PY

exit 0
