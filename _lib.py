from datetime import datetime

# (input, cache_write_5m, cache_read, output) per million tokens.
# Keys are the unversioned model family; lookup_pricing strips date suffixes
# like "-20251001" before matching, so dated IDs in transcripts still resolve.
# Verify against https://www.anthropic.com/pricing whenever a new model ships.
PRICING = {
    'claude-opus-4-7':    (15.00, 18.75, 1.50, 75.00),
    'claude-sonnet-4-6':  ( 3.00,  3.75, 0.30, 15.00),
    'claude-haiku-4-5':   ( 1.00,  1.25, 0.10,  5.00),
}
DEFAULT_PRICING = (3.00, 3.75, 0.30, 15.00)  # Sonnet as fallback


def lookup_pricing(model_id):
    """Return the pricing tuple for a transcript `model` string.

    Transcripts sometimes carry dated IDs (e.g. `claude-haiku-4-5-20251001`)
    that don't match the canonical PRICING keys. We try exact match first,
    then progressively strip trailing `-xxx` segments until we find a hit.
    Falls back to Sonnet pricing when nothing matches.
    """
    if not model_id:
        return DEFAULT_PRICING
    if model_id in PRICING:
        return PRICING[model_id]
    parts = model_id.split('-')
    while len(parts) > 1:
        parts.pop()
        candidate = '-'.join(parts)
        if candidate in PRICING:
            return PRICING[candidate]
    return DEFAULT_PRICING


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


def turn_cost_usd(turn, model_id):
    """Bill a deduped turn against the given model's pricing.

    `turn` is a list of (msg_id, usage) pairs. Each unique API call is
    billed independently — cache_read counts on every call that hits cache,
    because Anthropic charges for each cache_read on each request.
    """
    p = lookup_pricing(model_id)
    usages = dedupe_turn(turn)
    inp = sum(u.get('input_tokens', 0) for u in usages)
    cw  = sum(u.get('cache_creation_input_tokens', 0) for u in usages)
    cr  = sum(u.get('cache_read_input_tokens', 0) for u in usages)
    out = sum(u.get('output_tokens', 0) for u in usages)
    cost = (inp * p[0] + cw * p[1] + cr * p[2] + out * p[3]) / 1_000_000
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
