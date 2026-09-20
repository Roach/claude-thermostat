import glob
import json
import os
import sys
import time
from datetime import datetime

# (input, cache_write_5m, cache_read, output, cache_write_1h) per million
# tokens. The 1h rate is 2x input; the 5m rate is 1.25x.
#
# Source: https://platform.claude.com/docs/en/about-claude/pricing
# Verified 2026-09-20 against the published table. Cache read is 0.1x input
# on every family EXCEPT Fable 5.1 / Mythos 5.1, which are 0.025x — their
# own rows exist so they don't suffix-strip onto the 5 rows and get billed 4x.
#
# Claude Code main sessions write the cache at the 1h tier; subagent
# transcripts use 5m. Both are billed from their own slot.
# Keys are the unversioned model family; lookup_pricing strips date suffixes
# like "-20251001" before matching, so dated IDs in transcripts still resolve.
# Verify against https://www.anthropic.com/pricing whenever a new model ships.
PRICING = {
    'claude-fable-5-1':   (10.00, 12.50, 0.25, 50.00, 20.00),
    'claude-mythos-5-1':  (10.00, 12.50, 0.25, 50.00, 20.00),
    'claude-fable-5':     (10.00, 12.50, 1.00, 50.00, 20.00),
    'claude-mythos-5':    (10.00, 12.50, 1.00, 50.00, 20.00),
    'claude-opus-5':      ( 5.00,  6.25, 0.50, 25.00, 10.00),
    'claude-opus-4-8':    ( 5.00,  6.25, 0.50, 25.00, 10.00),
    'claude-opus-4-7':    ( 5.00,  6.25, 0.50, 25.00, 10.00),
    'claude-opus-4-6':    ( 5.00,  6.25, 0.50, 25.00, 10.00),
    'claude-opus-4-5':    ( 5.00,  6.25, 0.50, 25.00, 10.00),
    'claude-sonnet-5':    ( 2.00,  2.50, 0.20, 10.00,  4.00),
    'claude-sonnet-4-6':  ( 3.00,  3.75, 0.30, 15.00,  6.00),
    'claude-sonnet-4-5':  ( 3.00,  3.75, 0.30, 15.00,  6.00),
    'claude-haiku-4-5':   ( 1.00,  1.25, 0.10,  5.00,  2.00),
}
DEFAULT_PRICING = (3.00, 3.75, 0.30, 15.00, 6.00)  # Sonnet 4.6 rates; see _warn_unpriced

_warned_models = set()


def _warn_unpriced(model_id):
    """Warn once per model id that we are guessing its price."""
    if model_id in _warned_models:
        return
    _warned_models.add(model_id)
    sys.stderr.write(
        f'thermostat: no pricing entry for {model_id!r}; using fallback rates '
        f'— costs for this model are wrong. Add it to PRICING in _lib.py.\n')

def _resolve_key(model_id):
    """Return the PRICING key `model_id` maps to, or None if it is unpriced.

    Transcripts carry dated ids (`claude-haiku-4-5-20251001`) and a Claude Code
    context-tier suffix (`claude-fable-5[1m]`). Strip the suffix, try an exact
    match, then drop trailing `-xxx` segments until one hits. The `[1m]` tier
    carries no pricing premium on any current model, so dropping it is
    billing-neutral.
    """
    if not model_id:
        return None
    model_id = model_id.split('[')[0]
    if model_id in PRICING:
        return model_id
    parts = model_id.split('-')
    while len(parts) > 1:
        parts.pop()
        candidate = '-'.join(parts)
        if candidate in PRICING:
            return candidate
    return None


def lookup_pricing(model_id):
    """Return the pricing tuple for a transcript `model` string.

    An unpriced model falls back to DEFAULT_PRICING and warns on stderr; a
    silent fallback misprices every session on that model.
    """
    key = _resolve_key(model_id)
    if key is None:
        _warn_unpriced(model_id)
        return DEFAULT_PRICING
    return PRICING[key]


def sonnet_savings(model_id):
    """How many times cheaper Sonnet 5's output is than `model_id`'s, or None.

    None means there is no honest number to show — either the model is
    unpriced (the ratio would be derived from DEFAULT_PRICING, i.e. invented)
    or it is not more expensive than Sonnet. Callers omit the suggestion
    rather than print a fabricated figure. Output price alone is
    representative: input, cache and output ratios are uniform per family.
    """
    key = _resolve_key(model_id)
    if key is None:
        return None
    cur, son = PRICING[key][3], PRICING['claude-sonnet-5'][3]
    if not son or cur <= son:
        return None
    return cur / son


def dedupe_turn(turn):
    """Collapse duplicate usage entries (same Anthropic `message.id`).

    Claude Code's transcript re-appends an assistant message every time a
    tool round-trip happens — same `msg_xxx` id, same usage block, multiple
    rows. Billing-correct accounting treats each unique message.id as one
    API call. `turn` is a list of (msg_id, usage_dict); we return a list of
    usage dicts, one per unique message.id, preserving order.
    """
    seen = set()
    out = []
    for msg_id, usage in turn:
        # Fallback to id(usage) when message.id is missing — avoids collapsing
        # legitimately distinct rows that happen to lack an id.
        key = msg_id or f"_anon_{id(usage)}"
        if key in seen:
            continue
        seen.add(key)
        out.append(usage)
    return out


def turn_cost_usd(turn, model_id, mode='api'):
    """Bill a deduped turn against the given model's pricing.

    `turn` is a list of (msg_id, usage) pairs. Each unique API call is billed
    independently. `mode` selects which billing model to use:

      'api'          — public API pay-as-you-go rates. Includes cache_read at
                       0.1x input. This is what Anthropic charges for raw API
                       usage and what the published pricing pages reflect.

      'subscription' — matches the cost Claude Code displays in its statusline.
                       Excludes cache_read entirely. For users on Max / Pro /
                       Team / Enterprise plans this aligns with the number
                       Anthropic counts against the plan. The dollar figure
                       produced is an API-equivalent estimate, not actual
                       charges (subscription users are not billed per-token).

      'claude-code'  — accepted as an alias for 'subscription' (legacy name).

    Returns (cost, inp, cw, cr, out) — token counts are returned regardless
    of mode so callers can still surface them in headers and reports.
    """
    p = lookup_pricing(model_id)
    usages = dedupe_turn(turn)
    inp = sum(u.get('input_tokens', 0) for u in usages)
    cw  = sum(u.get('cache_creation_input_tokens', 0) for u in usages)
    cr  = sum(u.get('cache_read_input_tokens', 0) for u in usages)
    out = sum(u.get('output_tokens', 0) for u in usages)
    # Cache writes bill 1.25x input at the 5m tier and 2x at 1h. Transcripts
    # since ~Aug 2026 break the split out in `cache_creation`; without it we
    # can only assume 5m. Main sessions run 1h, so pricing the whole lot at
    # the 5m rate understated every cache write by 60%.
    cw1 = sum((u.get('cache_creation') or {}).get('ephemeral_1h_input_tokens', 0)
              for u in usages)
    cw5 = cw - cw1
    # 'subscription' and its legacy alias 'claude-code' both drop cache_read;
    # only 'api' bills it at the 0.1x input rate.
    cr_cost = cr * p[2] if mode == 'api' else 0
    cost = (inp * p[0] + cw5 * p[1] + cw1 * p[4] + cr_cost + out * p[3]) / 1_000_000
    return cost, inp, cw, cr, out


def is_real_user(msg_obj):
    """A 'real' user message starts a new turn. tool_result-only user
    messages are part of an in-flight assistant turn and don't reset."""
    content = msg_obj.get('message', {}).get('content')
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        if not content:
            return True
        if all(isinstance(c, dict) and c.get('type') == 'tool_result' for c in content):
            return False
        return True
    return True


def _parse_ts_unix(ts):
    if not ts:
        return 0
    try:
        return datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
    except Exception:
        return 0


def _weighted_tokens(usage, count_cached):
    """Sum a usage block into a single quota-weight integer.

    `count_cached=True` weights cache_read at 1.0x — the conservative default
    when we don't know how Anthropic charges cached reads against a
    subscription window. Set to False to exclude cache_read entirely
    (matches an "API-style 0.1x" worldview that just drops them for the
    subscription view).
    """
    if not usage:
        return 0
    total = (
        usage.get('input_tokens', 0)
        + usage.get('cache_creation_input_tokens', 0)
        + usage.get('output_tokens', 0)
    )
    if count_cached:
        total += usage.get('cache_read_input_tokens', 0)
    return total


def _project_transcripts():
    root = os.path.expanduser('~/.claude/projects')
    if not os.path.isdir(root):
        return []
    return glob.glob(os.path.join(root, '*', '*.jsonl'))


def update_window_index(index_path, count_cached=True, max_age_sec=25200):
    """Refresh the rolling-window index for all known transcripts.

    Per-transcript entries store (ts_unix, model, tokens, msg_id). On each
    call we tail-scan from the last byte offset, parse any new assistant
    messages, and append their weighted tokens. Entries older than
    `max_age_sec` are pruned at the end. Falls back to a full re-scan when
    a transcript has shrunk (rotated/truncated) or when its size doesn't
    match what we last saw.

    Returns the in-memory index dict so callers can sum without re-reading
    it from disk.
    """
    os.makedirs(os.path.dirname(index_path), exist_ok=True)
    try:
        index = json.load(open(index_path)) if os.path.exists(index_path) else {}
    except Exception:
        index = {}
    if not isinstance(index, dict) or 'transcripts' not in index:
        index = {'transcripts': {}}
    transcripts = index['transcripts']

    live_paths = set(_project_transcripts())
    # Drop entries for transcripts that have disappeared entirely.
    for stale in [p for p in transcripts if p not in live_paths]:
        del transcripts[stale]

    cutoff = time.time() - max_age_sec

    for path in live_paths:
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        rec = transcripts.get(path) or {'size': 0, 'offset': 0, 'entries': []}
        # Truncation / rotation: start over.
        if size < rec.get('size', 0):
            rec = {'size': 0, 'offset': 0, 'entries': []}
        offset = rec.get('offset', 0)
        if offset > size:
            offset = 0
        new_entries = []
        try:
            with open(path, 'rb') as f:
                f.seek(offset)
                # Read whole tail; assistant messages are line-delimited JSON.
                tail = f.read()
                # If the file ends mid-line, leave that fragment for next pass.
                last_nl = tail.rfind(b'\n')
                if last_nl < 0:
                    consumed = 0
                    tail = b''
                else:
                    consumed = last_nl + 1
                    tail = tail[:consumed]
                for raw in tail.splitlines():
                    if not raw.strip():
                        continue
                    try:
                        obj = json.loads(raw.decode('utf-8', errors='replace'))
                    except Exception:
                        continue
                    if obj.get('type') != 'assistant':
                        continue
                    msg = obj.get('message', {}) or {}
                    usage = msg.get('usage')
                    if not usage:
                        continue
                    ts = _parse_ts_unix(obj.get('timestamp'))
                    if ts < cutoff:
                        continue
                    model = msg.get('model') or 'unknown'
                    tokens = _weighted_tokens(usage, count_cached)
                    if tokens <= 0:
                        continue
                    new_entries.append([ts, model, tokens, msg.get('id') or ''])
                rec['offset'] = offset + consumed
                rec['size'] = size
        except OSError:
            continue
        # Merge + prune in one pass.
        merged = [e for e in (rec.get('entries') or []) if e[0] >= cutoff]
        merged.extend(new_entries)
        rec['entries'] = merged
        transcripts[path] = rec

    try:
        tmp = index_path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(index, f)
        os.replace(tmp, index_path)
    except OSError:
        pass

    return index


def tokens_in_window(window_sec, index, dedupe=True):
    """Sum window-indexed tokens by model, optionally deduping by msg_id.

    Same Anthropic message can be re-appended (tool round-trips) and end up
    in the index twice. We dedupe on msg.id at query time so the count
    matches one-API-call-per-message.
    """
    cutoff = time.time() - window_sec
    seen = set()
    totals = {}
    for path, rec in (index.get('transcripts') or {}).items():
        for ts, model, tokens, mid in rec.get('entries') or []:
            if ts < cutoff:
                continue
            if dedupe and mid:
                if mid in seen:
                    continue
                seen.add(mid)
            totals[model] = totals.get(model, 0) + tokens
    return totals


def format_token_count(n):
    """Compact human format: 1234 -> 1.2K, 1_500_000 -> 1.5M."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K"
    return str(n)


def in_session(obj, start_unix):
    if start_unix <= 0:
        return True
    ts = obj.get('timestamp', '')
    if not ts:
        return True
    try:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        return dt.timestamp() >= start_unix - 5
    except Exception:
        return True
