# claude-thermostat

Hooks that watch Claude Code session cost and produce a post-session cooldown report.

## Key files

- `claude-thermostat.sh` — in-session cost-threshold alert, invoked by the `Stop` event
- `cooldown-report.sh` — post-session cost-reduction post-mortem, invoked by the `SessionEnd` event; writes to `~/.claude/thermostat/reports/<session_id>.md` and appends a line to `~/.claude/thermostat/reports.log`
- `print-latest-cooldown.sh` — pretty-prints a cooldown report to the terminal (intended for use from a `claude` shell wrapper after the process exits)
- `_lib.py` — shared pricing table, dedup helpers, session-filter helpers
- State files: `~/.claude/thermostat/<session_id>.json`
- Optional config: `~/.claude/thermostat/config.env` (sourced at the top of the thermostat hook; overrides env vars)

## How the thermostat works

1. Reads `session_id`, `transcript_path`, `stop_hook_active` from stdin JSON
2. Skips immediately if `stop_hook_active` is true (prevents loop after the previous fire re-activates Claude)
3. Parses the transcript JSONL for actual token usage per assistant turn; computes cost estimate using per-model pricing
4. Checks four signals: session age, turn count, cost, and last-turn context size
5. If a setpoint is crossed AND the cooldown (turns since last fire) has elapsed: prints the alert to stderr, exits 2
6. Exit 2 from a Stop hook re-activates Claude, which relays the alert to the user

## Setpoints

All configurable via env vars (see README). Cost is the only enabled trigger by default ($50). Time, turn count, and context size all default to `0` (disabled) — they still get computed and displayed in the header, but don't fire on their own. Antipattern detection is on by default and fires regardless of cost.

## Pricing map

Lives in `_lib.py` as `PRICING` (a `{model_id: (input, cache_write, cache_read, output)}` map in per-million-token dollars). `lookup_pricing()` strips trailing `-YYYYMMDD` suffixes before matching, so dated transcript IDs (e.g. `claude-haiku-4-5-20251001`) still resolve. Update when Anthropic changes pricing or adds new models, and verify against https://www.anthropic.com/pricing.

## Billing correctness

Claude Code's transcript re-appends the same assistant message (same `message.id`) on every tool round-trip. `_lib.dedupe_turn` collapses by `message.id` before billing, so input/cache-write/output are each counted once per real API call. Cache_read is billed on every unique call (Anthropic charges cache-read per request that hits cache).

## Cooldown (deadband)

Measured in turns (`last_nag_turn` vs current `turn_count`), not seconds. An idle session doesn't re-fire on first resumption — it takes `COOLDOWN_TURNS` of actual work.
