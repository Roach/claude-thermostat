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

# Same optional config the Stop hook sources — keeps the tuning suggestions
# comparing against the user's real setpoints, not the defaults. set -a so
# the values reach the python child process.
CONFIG_FILE="${CLAUDE_THERMOSTAT_CONFIG:-$STATE_DIR/config.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$CONFIG_FILE"; set +a
fi

input="$(cat)"

{ read -r session_id; read -r transcript_path; read -r reason; } < <(
  printf '%s' "$input" | /usr/bin/python3 -c \
    "import json,sys; d=json.load(sys.stdin); [print(d.get(k,'')) for k in ['session_id','transcript_path','reason']]" 2>/dev/null
)
[ -z "$session_id" ] && exit 0
{ [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; } && exit 0

# Read session_start and nag_history from state file.
state_file="$STATE_DIR/${session_id}.json"
session_start=0
if [ -f "$state_file" ]; then
  session_start=$(STATE_FILE="$state_file" /usr/bin/python3 -c \
    "import json,os; d=json.load(open(os.environ['STATE_FILE'])); print(d.get('session_start',0))" 2>/dev/null || echo 0)
fi

TUNING_FILE="$STATE_DIR/tuning.json"

# Use the pre-session path exported by the shell wrapper if available; this
# lets the wrapper print the exact file without any age-based guessing.
REPORT_FILE="${CLAUDE_COOLDOWN_FILE:-$REPORT_DIR/${session_id}.md}"
mkdir -p "$(dirname "$REPORT_FILE")"

/usr/bin/python3 - "$transcript_path" "$session_id" "$reason" "$REPORT_FILE" "$LOG" "$session_start" "$state_file" "$TUNING_FILE" <<'PY'
import json, os, sys, re, time
from collections import Counter, defaultdict
from datetime import datetime

sys.path.insert(0, os.environ['THERMOSTAT_LIB_DIR'])
from _lib import (
    is_real_user, in_session, turn_cost_usd, dedupe_turn, lookup_pricing,
    update_window_index, tokens_in_window, format_token_count,
    _SONNET_5_INTRO_END,
)

path, session_id, reason, report_file, log_file = sys.argv[1:6]
start_unix  = int(sys.argv[6]) if len(sys.argv) > 6 else 0
state_file  = sys.argv[7] if len(sys.argv) > 7 else ''
tuning_file = sys.argv[8] if len(sys.argv) > 8 else ''
cost_mode = os.environ.get('CLAUDE_THERMOSTAT_COST_MODE', 'api')

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
thinking_blocks = 0   # count of extended-thinking content blocks (bill as output)
first_ts = last_ts = None
usage_seq = []            # (ts_unix, model, usage) per unique assistant API call
first_overhead = None     # input+cache_write of the first API call = session-start context
tool_errors = 0           # tool_result blocks that came back is_error
read_seq = []             # ordered Read file paths (post-compact re-read check)
compact_read_pos = None   # len(read_seq) at the most recent compact boundary
compacts = 0

def _ts_unix(ts):
    try:
        return datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
    except Exception:
        return 0

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
            _uc = obj.get('message', {}).get('content')
            if isinstance(_uc, list):
                tool_errors += sum(1 for x in _uc if isinstance(x, dict)
                                   and x.get('type') == 'tool_result' and x.get('is_error'))
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
            if usage:
                _ov = ((usage.get('input_tokens', 0) or 0)
                       + (usage.get('cache_creation_input_tokens', 0) or 0))
                if first_overhead is None:
                    first_overhead = _ov
                usage_seq.append((_ts_unix(ts), m or current_model or 'unknown', usage))
            content = msg.get('content', [])
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'thinking':
                        thinking_blocks += 1
                    if isinstance(c, dict) and c.get('type') == 'tool_use':
                        name = c.get('name', '?')
                        inp = c.get('input') or {}
                        if name == 'Read':
                            key = (inp.get('file_path') or '').strip()
                            if key:
                                read_seq.append(key)
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
        elif t == 'system':
            if obj.get('subtype') == 'compact_boundary' and in_session(obj, start_unix):
                compacts += 1
                compact_read_pos = len(read_seq)
if current:
    turns.append(current)
    model_per_turn.append(current_model or 'unknown')

# --- cost ---
# Bill each unique Anthropic message.id once, per turn, per the turn's model.
# turn_cost_usd handles dedupe + dated model-id prefix matching.
total_usd = 0.0
per_model_usd = Counter()
per_model_tokens = defaultdict(lambda: [0, 0, 0, 0])  # in, cache_write, cache_read, out
total_in = total_cw = total_cr = total_out = 0
for turn, model in zip(turns, model_per_turn):
    if not turn: continue
    cost, inp, cw, cr, out = turn_cost_usd(turn, model, mode=cost_mode)
    total_usd += cost
    per_model_usd[model] += cost
    pmt = per_model_tokens[model]
    pmt[0] += inp; pmt[1] += cw; pmt[2] += cr; pmt[3] += out
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
#    Source code files (.py, .ts, .js, etc.) go to a "codegraph" bucket instead —
#    they should be queried via mcp__codegraph__codegraph_explore, not bundled
#    into a skill.
SKILL_EXTS = {
    '.md', '.html', '.htm', '.yaml', '.yml', '.json', '.toml', '.txt',
    '.sql', '.env', '.cfg', '.ini', '.conf',
}
SOURCE_EXTS = {
    '.py', '.ts', '.tsx', '.js', '.jsx', '.go', '.rb', '.rs', '.java',
    '.kt', '.swift', '.c', '.cpp', '.h', '.sh', '.bash',
}

def _ext(fpath):
    _, e = os.path.splitext(fpath)
    return e.lower()

read_counts = Counter(k for n, k, _, _ in tool_calls if n == 'Read' and k)
# Exclude files we also edited — Claude Code re-Reads after every Edit by
# design, so an edited file's Read count is noise, not a skill candidate.
# Skills are for reference material, not source you're modifying.
edited_files = {k for n, k, _, _ in tool_calls
                if n in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') and k}
for f, n in read_counts.most_common(8):
    if n < 3 or f in edited_files:
        continue
    ext = _ext(f)
    if ext in SOURCE_EXTS:
        suggestions.append((
            'codegraph',
            f"Read `{f}` {n}× — use `mcp__codegraph__codegraph_explore` (or `codegraph explore` in-shell) for lookups into this file instead of re-reading it"
        ))
    else:
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
            f"Grep `{pat}` {n}× — same exploration repeated; consider a skill with the answer pre-written, or mcp__codegraph__codegraph_explore"
        ))

# 2) CodeGraph / grep-chain
grep_read = sum(1 for n, _, _, _ in tool_calls if n in ('Grep', 'Read', 'Glob'))
total_tools = len(tool_calls) or 1
if grep_read >= 30 and grep_read / total_tools > 0.4:
    suggestions.append((
        'tool',
        f"{grep_read} Grep/Read/Glob calls ({100*grep_read//total_tools}% of all tool use) — heavy codebase exploration. Try `mcp__codegraph__codegraph_explore` for natural-language lookups; one call replaces a chain"
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

# 4) Model choice — premium-tier (Opus/Fable) turns that produced trivial
#    output are downgrade candidates. Ratios come from the live pricing
#    table so they stay accurate when rates change.
PREMIUM = ('claude-opus', 'claude-fable', 'claude-mythos')
prem_turns = [(t, m) for t, m in zip(turns, model_per_turn) if m.startswith(PREMIUM)]
if prem_turns and per_model_usd:
    prem_usd = sum(c for m, c in per_model_usd.items() if m.startswith(PREMIUM))
    prem_share = prem_usd / max(total_usd, 1e-9)
    if prem_share > 0.5 and total_usd > 1.0:
        cheap_count = 0
        for t, _ in prem_turns:
            out = sum(u.get('output_tokens', 0) for _, u in t)
            if out < 500: cheap_count += 1
        if cheap_count >= 3:
            prem_out = lookup_pricing(prem_turns[0][1])[3]
            son_x = prem_out / lookup_pricing('claude-sonnet-5')[3]
            hai_x = prem_out / lookup_pricing('claude-haiku-4-5')[3]
            label = 'Opus' if prem_turns[0][1].startswith('claude-opus') else 'Fable'
            suggestions.append((
                'model',
                f"{cheap_count} {label} turn(s) produced <500 output tokens — these were small lookups/edits that Sonnet (~{son_x:.1f}× cheaper) or Haiku (~{hai_x:.0f}× cheaper) would have handled. Use `/model sonnet` for routine work; reserve {label} for hard reasoning"
            ))

# 5) Cache hit rate — low cache_read ratio means context churn (rules
#    reshuffling, lots of /clear), each turn pays full input. Try to name
#    the specific cause rather than listing generic possibilities.
inp_paid = total_in + total_cw
if inp_paid + total_cr > 50_000:
    ratio = total_cr / max(total_cr + inp_paid, 1)
    if ratio < 0.4:
        causes = []
        # Per-turn cache hit to find sharp drop points.
        per_turn_hits = []
        for turn in turns:
            if not turn: continue
            usages = dedupe_turn(turn)
            cr   = sum(u.get('cache_read_input_tokens', 0) for u in usages)
            paid = (sum(u.get('input_tokens', 0) for u in usages)
                    + sum(u.get('cache_creation_input_tokens', 0) for u in usages))
            per_turn_hits.append(cr / max(cr + paid, 1))
        drop_turns = [i + 1 for i in range(1, len(per_turn_hits))
                      if per_turn_hits[i - 1] > 0.6 and per_turn_hits[i] < 0.3]
        if drop_turns:
            causes.append(f"sharp cache drop at turn(s) {', '.join(str(t) for t in drop_turns)}")
        if len(set(m for m in model_per_turn if m != 'unknown')) > 1:
            causes.append("model switch(es) mid-session")
        if per_turn_hits and per_turn_hits[0] < 0.3:
            causes.append("session started cold — large auto-loading rules or first session of the day")
        cause_str = "; ".join(causes) if causes else "large auto-loading rules, frequent /clear, or context shape changes"
        uncached_hint = (
            "most input was uncached (full price)"
            if cost_mode == 'api'
            else "most input was uncached (counts against your token quota at full weight)"
        )
        suggestions.append((
            'context',
            f"Cache hit rate {ratio*100:.0f}% — {uncached_hint}. Detected: {cause_str}. Audit `~/.claude/rules/` for big files that could be skills"
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

# 7) Model switch mid-session resets the KV cache; all turns after pay full
#    input price until the new model's cache warms back up.
if len(turns) > 2:
    switches = []
    prev_m = None
    for i, m in enumerate(model_per_turn):
        if m == 'unknown':
            continue
        if prev_m and m != prev_m:
            switches.append((i + 1, prev_m, m))
        prev_m = m
    if switches:
        parts = ', '.join(
            f"turn {i}: {a.replace('claude-', '')}→{b.replace('claude-', '')}"
            for i, a, b in switches
        )
        suggestions.append((
            'context',
            f"Model switch(es) mid-session ({parts}) — each switch resets the KV cache; turns after the switch pay full input price until the cache warms up"
        ))

# 8) Subagent under-use when context grew large.
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

# 9) Long, hot session likely to hit auto-compaction — a fresh session is
#    cleaner than continuing on a compacted (lossy) transcript. Recommend the
#    checkpoint ritual: commit + push, then restart. Git history becomes the
#    durable context instead of an ever-growing conversation.
if turns and turns[-1]:
    _last = dedupe_turn(turns[-1])
    _lu = _last[-1] if _last else {}
    _ctx = (_lu.get('input_tokens', 0)
            + _lu.get('cache_creation_input_tokens', 0)
            + _lu.get('cache_read_input_tokens', 0))
    if _ctx > 140_000 and len(turns) >= 20:
        suggestions.append((
            'context',
            f"Session ran long and hot ({len(turns)} turns, final context {_ctx//1000}K) — at this size you're near auto-compaction, which keeps you on a lossy transcript. If the current chunk of work is done, commit + push to checkpoint it, then start a fresh session: git history carries the context forward more cheaply than a compacted conversation. If you'd rather continue, steer the summary with `/compact <what to keep>` instead of letting it compact blind"
        ))

# 10) Extended thinking heavily used — thinking tokens bill as output. For
#     routine turns, lowering reasoning effort trims cost without hurting
#     quality on work that didn't need deep reasoning.
if thinking_blocks >= 20 and total_out > 60_000:
    suggestions.append((
        'model',
        f"{thinking_blocks} extended-thinking blocks and {total_out//1000}K output tokens this session — thinking bills as output. If much of this was routine, lower reasoning effort with `/effort` (or `MAX_THINKING_TOKENS=8000`), or add \"Prioritize responding quickly rather than thinking deeply; when in doubt, respond directly\" to CLAUDE.md for low-stakes work (per Anthropic's Opus 4.7 best-practices guide). Reserve deep thinking for hard problems"
    ))

# 11) MCP surface — tool definitions load into context, and CLI equivalents
#     are leaner. We can only see servers actually *used*; `/context` shows
#     the ones loaded-but-idle that are pure overhead.
mcp_servers = Counter()
for n, _, _, _ in tool_calls:
    if n.startswith('mcp__'):
        parts = n.split('__')
        if len(parts) >= 2 and parts[1]:
            mcp_servers[parts[1]] += 1
if len(mcp_servers) >= 2 or sum(mcp_servers.values()) >= 8:
    srv_list = ', '.join(f"{s} ({c}×)" for s, c in mcp_servers.most_common(5))
    suggestions.append((
        'tool',
        f"MCP tools used across {len(mcp_servers)} server(s): {srv_list}. Run `/context` to see what each costs and `/mcp` to disable any you're not using; prefer CLI equivalents (gh, aws, gcloud) where they exist — they add no per-tool listing to context"
    ))

# 12) Repeated reads/greps into build or dependency dirs — these belong in
#     .claudeignore so Claude stops exploring them and burning context.
IGNORE_DIRS = ('node_modules', 'dist', 'build', '.next', 'vendor',
               'target', '.venv', '__pycache__', 'site-packages')
ignore_hits = Counter()
for n, k, _, _ in tool_calls:
    if n in ('Read', 'Grep', 'Glob') and k:
        for d in IGNORE_DIRS:
            if f'/{d}/' in k or k.startswith(d + '/'):
                ignore_hits[d] += 1
                break
_ign_total = sum(ignore_hits.values())
if _ign_total >= 5:
    dirs = ', '.join(f"{d} ({c}×)" for d, c in ignore_hits.most_common(4))
    suggestions.append((
        'context',
        f"{_ign_total} reads/greps into build or dependency dirs ({dirs}) — add these to `.claudeignore` so they're excluded from exploration and don't waste context"
    ))

# 13) High-output turns with no Bash/Write/Edit — model doing deterministic
#     work inline (data transforms, arithmetic, formatting, row-by-row
#     reformatting) instead of scripting it. Scripts are faster, cheaper,
#     and always produce the same answer.
OUTPUT_INLINE_THRESH = 4000
turns_with_scripts = {ti for n, _, _, ti in tool_calls
                      if n in ('Bash', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit')}
high_output_inline = []
for _ti, _turn in enumerate(turns):
    if not _turn: continue
    _usages = dedupe_turn(_turn)
    _out_tok = sum(u.get('output_tokens', 0) for u in _usages)
    if _out_tok >= OUTPUT_INLINE_THRESH and _ti not in turns_with_scripts:
        high_output_inline.append(_out_tok)
if len(high_output_inline) >= 2:
    _total_inline_out = sum(high_output_inline)
    suggestions.append((
        'tool',
        f"{len(high_output_inline)} turns with ≥{OUTPUT_INLINE_THRESH} output tokens and no Bash/Write "
        f"({_total_inline_out//1000}K tokens total) — model may have computed or reformatted data "
        f"inline instead of scripting it. Install the deterministic-toolkit skill shipped "
        f"with claude-thermostat (`skills/deterministic-toolkit.md`) for mechanical work: parsing, converting formats, deduping, "
        f"aggregating, validating, diffing. Scripts are deterministic; in-context arithmetic "
        f"and reformatting are not."
    ))

# 14) Fixed session-start overhead — the first API call's input+cache_write is
#     the context loaded before the first word: CLAUDE.md, rules, memory files,
#     MCP tool schemas. Every session pays to write it and every turn to read it.
if first_overhead and first_overhead >= 30_000:
    suggestions.append((
        'context',
        f"Session-start overhead was {first_overhead//1000}K tokens loaded before your first prompt "
        f"(CLAUDE.md, rules, memory, MCP tool schemas). Every session re-caches this and every turn "
        f"re-reads it — run `/context` for the breakdown, move big rules into on-demand skills, "
        f"and `/mcp` to disable idle servers"
    ))

# 15) Cache expirations — the prompt cache TTL is 5 minutes. A call that
#     follows a longer idle gap re-writes the context at 1.25x input instead
#     of reading it at 0.1x. Detected: >5.5min gap AND a large cache_write on
#     the following call.
expiries = 0
expiry_wasted_usd = 0.0
_prev_ts = None
for _tsu, _mdl, _u in usage_seq:
    _cw = _u.get('cache_creation_input_tokens', 0) or 0
    if _prev_ts and _tsu and _tsu - _prev_ts > 330 and _cw > 20_000:
        _p = lookup_pricing(_mdl)
        expiries += 1
        expiry_wasted_usd += _cw * (_p[1] - _p[2]) / 1_000_000
    if _tsu:
        _prev_ts = _tsu
if expiries >= 2:
    suggestions.append((
        'cache',
        f"{expiries} cache expiration(s): turns that followed a >5min idle gap re-wrote the full "
        f"context (~${expiry_wasted_usd:.2f} extra vs a warm cache — the 5-minute cache TTL had "
        f"lapsed). Batch prompts while the cache is warm, or close the session when stepping away"
    ))

# 16) Failed tool calls — each errored tool_result costs a full round-trip and
#     the error text stays in context. Recurring failures usually trace to one
#     fixable cause: a permission rule, a blocking hook, or a wrong path.
if tool_errors >= 5:
    suggestions.append((
        'tool',
        f"{tool_errors} tool calls returned errors this session — each failure costs a full API "
        f"round-trip and the error output stays in context. Recurring denials/failures usually "
        f"trace to one fixable cause: a permission rule, a blocking hook, or a wrong path"
    ))

# 17) Post-compact re-reads — files read before auto-compaction and again after
#     it are paid for twice: once into the original context, once more after
#     the summary dropped them.
if compacts and compact_read_pos is not None:
    _pre = set(read_seq[:compact_read_pos])
    _post = read_seq[compact_read_pos:]
    re_read = sorted({k for k in _post if k in _pre})
    if len(re_read) >= 2:
        _sample = ', '.join(f'`{os.path.basename(k)}`' for k in re_read[:3])
        if len(re_read) > 3:
            _sample += ', …'
        suggestions.append((
            'context',
            f"{len(re_read)} file(s) re-read after compaction ({_sample}) — compaction dropped "
            f"content you paid to read, then you paid to read it again. Steer it with "
            f"`/compact <what to keep>`, or checkpoint (commit + push) and start fresh before it triggers"
        ))

# 18) Sonnet 5 introductory pricing ends 2026-09-01 — flag when the flip is
#     close so the cost jump doesn't read as a regression.
if any('sonnet-5' in m for m in per_model_usd):
    _days_left = int((_SONNET_5_INTRO_END - time.time()) // 86400)
    if 0 <= _days_left <= 45:
        suggestions.append((
            'pricing',
            f"Heads-up: Sonnet 5 introductory pricing ($2/$10 per MTok) ends 2026-09-01 "
            f"({_days_left} days) — costs will rise ~50% at standard rates ($3/$15). "
            f"Not a regression when it happens"
        ))

# 19) Multi-day / stale session — a transcript left open half a day or more
#     keeps growing and re-billing, and every idle gap past the 5-minute TTL
#     restarts the cache cold. Distinct from #9 (context size): this fires on
#     wall-clock span even when context stayed modest.
if first_ts and last_ts:
    _a, _b = parse_ts(first_ts), parse_ts(last_ts)
    if _a and _b:
        _span_h = (_b - _a).total_seconds() / 3600
        if _span_h >= 12 and len(turns) >= 10:
            _span_str = f"{_span_h/24:.1f} days" if _span_h >= 48 else f"{_span_h:.0f}h"
            suggestions.append((
                'context',
                f"This session stayed open {_span_str} across {len(turns)} turns — long-lived "
                f"sessions carry a stale, ever-growing transcript, and each idle gap over 5 min "
                f"expires the cache. Checkpoint with commit + push and start fresh: git history "
                f"is cheaper to reload than a multi-day conversation"
            ))

# --- tuning: update cross-session history and detect config patterns -----------

def _load_tuning(path):
    if not path or not os.path.exists(path):
        return {'sessions': []}
    try:
        return json.load(open(path))
    except Exception:
        return {'sessions': []}

def _save_tuning(path, data, max_sessions=20):
    if not path:
        return
    data['sessions'] = data['sessions'][-max_sessions:]
    try:
        tmp = path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        pass

# Read nag_history from the session state file.
nag_history = []
if state_file and os.path.exists(state_file):
    try:
        nag_history = json.load(open(state_file)).get('nag_history', [])
    except Exception:
        pass

# Append this session to the tuning log.
tuning = _load_tuning(tuning_file)
nag_count_session = len(nag_history)
tuning['sessions'].append({
    'session_id': session_id,
    'date':       datetime.now().date().isoformat(),
    'cost_cents': int(round(total_usd * 100)),
    'nag_count':  nag_count_session,
    'nag_history': nag_history,
})
_save_tuning(tuning_file, tuning)

def _tuning_suggestions(sessions, cost_thresh_cents):
    """Detect config patterns across recent sessions and return suggestion strings."""
    suggs = []
    nagged = [s for s in sessions if s.get('nag_count', 0) > 0]
    recent = sessions[-10:]
    recent_nagged = [s for s in recent if s.get('nag_count', 0) > 0]

    if len(sessions) < 3:
        return suggs   # not enough data yet

    # 1. Setpoint calibration: user routinely keeps going past the alert.
    #    Signal: session end-cost is ≥1.5× the cost at first nag, across ≥3 sessions.
    overruns = []
    for s in recent_nagged[-6:]:
        hist = s.get('nag_history') or []
        if hist and s['cost_cents'] > 0:
            first_nag = hist[0]['cost_cents']
            if first_nag > 0:
                overruns.append(s['cost_cents'] / first_nag)
    if len(overruns) >= 3 and sum(overruns) / len(overruns) >= 1.5:
        avg_end = int(sum(s['cost_cents'] for s in recent_nagged[-6:]) / len(recent_nagged[-6:]))
        suggested = int(avg_end * 0.8)   # 80% of typical end cost → fires a bit earlier
        current_dollars = cost_thresh_cents / 100
        suggs.append(
            f"You typically continue well past the alert (avg session cost "
            f"${avg_end/100:.0f} vs ${current_dollars:.0f} setpoint). "
            f"Consider `CLAUDE_THERMOSTAT_COST_CENTS={suggested}` to catch it "
            f"earlier, or raise the setpoint to reduce noise."
        )

    # 2. Context setpoint: context is large at most nag events.
    nag_ctxs = [n['context_k'] for s in recent for n in (s.get('nag_history') or []) if n.get('context_k', 0) > 0]
    if len(nag_ctxs) >= 4:
        above_100 = sum(1 for k in nag_ctxs if k >= 100)
        if above_100 / len(nag_ctxs) >= 0.6:
            median_ctx = sorted(nag_ctxs)[len(nag_ctxs) // 2]
            suggs.append(
                f"Context is above 100K tokens at alert time in "
                f"{above_100}/{len(nag_ctxs)} recent nags (median {median_ctx}K). "
                f"Enable `CLAUDE_THERMOSTAT_CONTEXT_K=90` to catch it earlier, "
                f"when `/compact` recovers more context."
            )

    # 3. Persistent antipatterns: antipatterns dominate triggers across sessions.
    all_triggers = [t for s in recent for n in (s.get('nag_history') or []) for t in n.get('triggers', [])]
    if len(all_triggers) >= 5:
        ap_share = sum(1 for t in all_triggers if t == 'antipattern') / len(all_triggers)
        if ap_share >= 0.6:
            suggs.append(
                f"Antipatterns trigger {int(ap_share*100)}% of your alerts across recent "
                f"sessions — the patterns aren't improving. Consider installing the "
                f"CodeGraph MCP (`mcp__codegraph__codegraph_explore`) as your primary "
                f"codebase search: one call replaces most Grep/Read chains."
            )

    # 4. Alert fatigue: 3+ nags per nagged session on average.
    if len(recent_nagged) >= 3:
        avg_nags = sum(s['nag_count'] for s in recent_nagged) / len(recent_nagged)
        if avg_nags >= 3:
            suggs.append(
                f"You average {avg_nags:.1f} alerts per session. If the alerts feel "
                f"noisy, raise `CLAUDE_THERMOSTAT_COOLDOWN_TURNS` (currently the "
                f"default 10) to widen the deadband, or increase the cost setpoint."
            )

    return suggs

cost_thresh_env = int(os.environ.get('CLAUDE_THERMOSTAT_COST_CENTS') or 5000)
tuning_suggs = _tuning_suggestions(tuning['sessions'], cost_thresh_env)

# --- write report ---
lines = []
lines.append(f"# Cooldown report — {session_id}")
lines.append("")
lines.append(f"- **Ended:** {datetime.now().isoformat(timespec='seconds')} (reason: {reason or 'unknown'})")
lines.append(f"- **Duration:** {dur_min or 'unknown'}")
lines.append(f"- **Turns:** {len(turns)}")
cost_mode_label = (
    "API rates (includes cache_read at 0.1x input)"
    if cost_mode == 'api'
    else "API-equivalent estimate — subscription users are not billed per-token; use token counts for quota tracking"
)
lines.append(f"- **Cost:** ${total_usd:.2f}  _— {cost_mode_label}_")
if per_model_usd:
    parts = ', '.join(f"{m.replace('claude-','')}=${c:.2f}" for m, c in per_model_usd.most_common() if round(c, 2) > 0)
    if parts:
        lines.append(f"- **By model:** {parts}")
lines.append(f"- **Tokens:** in={total_in:,} cache_write={total_cw:,} cache_read={total_cr:,} out={total_out:,}")
_active_models = [m for m, t in per_model_tokens.items() if sum(t) > 0]
if len(_active_models) > 1:
    for m, c in per_model_usd.most_common():
        t = per_model_tokens.get(m)
        if not t or sum(t) == 0: continue
        lines.append(
            f"  - {m.replace('claude-','')}: in={t[0]:,} cache_write={t[1]:,} "
            f"cache_read={t[2]:,} out={t[3]:,}"
        )
_paid = total_in + total_cw
_hit  = total_cr / max(total_cr + _paid, 1)
_hit_hint = "higher = cheaper" if cost_mode == 'api' else "higher = uses less quota"
lines.append(f"- **Cache hit:** {_hit*100:.0f}% ({_hit_hint}; <40% suggests context churn)")
if first_overhead:
    lines.append(f"- **Session-start overhead:** {first_overhead//1000}K tokens loaded before the first prompt")
if compacts:
    lines.append(f"- **Compactions:** {compacts} (context was summarized mid-session)")

# Rolling-window approximation (subscription-quota stand-in). Only included
# if the user has opted in by setting CLAUDE_THERMOSTAT_WINDOW_TOKENS. The
# number is local math across all transcripts, not a real /usage read — see
# the caveats block below.
window_thresh = int(os.environ.get('CLAUDE_THERMOSTAT_WINDOW_TOKENS', '0') or 0)
window_sec = int(os.environ.get('CLAUDE_THERMOSTAT_WINDOW_SEC', '18000') or 18000)
window_count_cached = os.environ.get('CLAUDE_THERMOSTAT_WINDOW_COUNT_CACHED', '1') == '1'
window_block = []
if window_thresh > 0:
    index_path = os.path.expanduser('~/.claude/thermostat/window-index.json')
    try:
        idx = update_window_index(index_path, count_cached=window_count_cached,
                                  max_age_sec=max(window_sec + 7200, 25200))
        totals = tokens_in_window(window_sec, idx)
        wsum = sum(totals.values())
        wh = window_sec // 3600
        lines.append(
            f"- **Window:** ~{format_token_count(wsum)} tokens in the last {wh}h "
            f"(local approximation; see notes)"
        )
        # Stash a per-model breakdown for the notes section.
        if totals:
            window_block = sorted(totals.items(), key=lambda kv: -kv[1])
    except Exception:
        pass

lines.append("")

if suggestions:
    lines.append("## Cost-reduction suggestions for next session")
    lines.append("")
    by_kind = defaultdict(list)
    for kind, s in suggestions:
        by_kind[kind].append(s)
    titles = {
        'skill':  'New skills to consider',
        'codegraph': 'Better search tool for source files',
        'tool':   'Better tool choices',
        'model':  'Model choice',
        'prompt': 'Prompt patterns',
        'context':'Context hygiene',
        'cache':  'Cache economics',
        'pricing':'Pricing changes',
    }
    for kind in ('model', 'skill', 'codegraph', 'tool', 'context', 'cache', 'prompt', 'pricing'):
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

if window_thresh > 0:
    wh = window_sec // 3600
    lines.append("## Subscription-window approximation — caveats")
    lines.append("")
    lines.append(
        f"The window number above is a **local approximation**, not your real "
        f"subscription quota. It sums weighted tokens across every Claude Code "
        f"transcript under `~/.claude/projects/` within the last {wh}h."
    )
    lines.append("")
    lines.append("- Anthropic's quota bucketing (sliding vs aligned to a reset boundary) isn't documented; this assumes a continuous rolling window.")
    cw_note = ("counted at 1.0x" if window_count_cached
               else "excluded (CLAUDE_THERMOSTAT_WINDOW_COUNT_CACHED=0)")
    lines.append(f"- `cache_read_input_tokens` are {cw_note}; real subscription weighting is unknown.")
    lines.append("- Only Claude Code traffic is counted. `claude.ai` web, direct API use, and other clients are invisible to this script.")
    lines.append("- `/usage` inside the CLI is still the source of truth for your actual quota state.")
    if window_block:
        lines.append("")
        lines.append("Breakdown by model in window:")
        for m, n in window_block:
            lines.append(f"- `{m}` — {format_token_count(n)} tokens")
    lines.append("")

# Configuration tuning suggestions (cross-session patterns, ≥3 sessions required)
if tuning_suggs:
    lines.append("## Configuration tuning")
    lines.append("")
    lines.append("_Based on patterns across your recent sessions:_")
    lines.append("")
    for s in tuning_suggs:
        lines.append(f"- {s}")
    lines.append("")

# "Review with Claude" command — short copyable one-liner at the bottom of the report.
lines.append("## Review with Claude")
lines.append("")
lines.append("```bash")
lines.append(f'claude "Review my thermostat cooldown report at {report_file} and help me apply the top suggestion"')
lines.append("```")
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
_tty = sys.stderr.isatty() and not os.environ.get('NO_COLOR')
def _c(code, s):
    return f"\033[{code}m{s}\033[0m" if _tty else s
BOLD, DIM = '1', '2'
CYAN, YELLOW, GREEN, RED, BLUE = '36', '33', '32', '31', '34'

_hit_color = GREEN if _hit >= 0.7 else (YELLOW if _hit >= 0.4 else RED)
print('', file=sys.stderr)
print(
    f"{_c(DIM, '━━━')} {_c(f'{BOLD};{CYAN}', 'cooldown-report')}  "
    f"{_c(f'{BOLD};{YELLOW}', f'${total_usd:.2f}')} · {len(turns)} turns · "
    f"{dur_min or '?'} · {_c(_hit_color, f'{_hit*100:.0f}% cached')} {_c(DIM, '━━━')}",
    file=sys.stderr,
)
if per_model_usd:
    parts = ', '.join(f"{m.replace('claude-','')}=${c:.2f}" for m, c in per_model_usd.most_common() if round(c, 2) > 0)
    if parts:
        print(f"  {_c(DIM, 'models:')} {parts}", file=sys.stderr)
if suggestions:
    titles = {
        'model':  'Model choice',
        'skill':  'New skills to consider',
        'codegraph': 'Better search tool for source files',
        'tool':   'Better tool choices',
        'context':'Context hygiene',
        'cache':  'Cache economics',
        'prompt': 'Prompt patterns',
        'pricing':'Pricing changes',
    }
    by_kind = defaultdict(list)
    for kind, s in suggestions:
        by_kind[kind].append(s)
    for kind in ('model', 'skill', 'codegraph', 'tool', 'context', 'cache', 'prompt', 'pricing'):
        if kind not in by_kind: continue
        print(f"\n  {_c(BOLD, titles[kind])}:", file=sys.stderr)
        for s in by_kind[kind]:
            # wrap-aware indent for readability
            print(f"    {_c(YELLOW, '•')} {s}", file=sys.stderr)
else:
    print(f"\n  {_c(GREEN, 'No notable inefficiencies detected.')}", file=sys.stderr)
if tuning_suggs:
    _n_sessions = len(tuning['sessions'])
    print(f"\n  {_c(BOLD, 'Configuration tuning')} {_c(DIM, f'({_n_sessions} sessions on record)')}:", file=sys.stderr)
    for s in tuning_suggs:
        print(f"    {_c(BLUE, '◆')} {s}", file=sys.stderr)
print(f"\n  {_c(DIM, 'Full report:')} {report_file}", file=sys.stderr)
print(f"  {_c(DIM, 'Review with Claude:')} claude \"Review my thermostat cooldown report at {report_file} and help me apply the top suggestion\"", file=sys.stderr)
print(_c(DIM, '━' * 60), file=sys.stderr)
PY

exit 0
