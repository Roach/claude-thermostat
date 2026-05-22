# claude-thermostat

A Claude Code hook that watches session cost and prompts you to `/compact`, `/clear`, or pivot before the bill balloons — plus a post-session **cooldown report** with cost-reduction suggestions for next time.

The metaphor is precise: a thermostat. Setpoint (`$CLAUDE_THERMOSTAT_COST_CENTS`), sensor (transcript parser), actuator (the alert), hysteresis (cooldown turns).

## What it does

Fires on every `Stop` event (when Claude finishes responding). Tracks:

- **Session age** — wall-clock time since the first turn
- **Turn count** — completed back-and-forth exchanges
- **Estimated cost** — parsed from the session transcript JSONL, using actual token counts and per-model pricing (Sonnet, Opus, Haiku). Deduplicates re-appended assistant messages by `message.id` so the estimate matches what Anthropic actually bills.
- **Context window size** — total input tokens on the most recent turn
- **Cache hit %** — share of input tokens that hit cache (higher = cheaper turns)

When the cost setpoint is crossed (or an antipattern is detected — see below), the hook exits `2`, which makes Claude surface the alert and ask the user what they'd like to do. After firing it re-arms after `CLAUDE_THERMOSTAT_COOLDOWN_TURNS` more turns (the deadband), so long sessions get periodic nudges without constant interruption.

## Files

- `claude-thermostat.sh` — the in-session alert, wired to `Stop`
- `cooldown-report.sh` — the post-session cost-reduction post-mortem, wired to `SessionEnd`
- `print-latest-cooldown.sh` — optional terminal pretty-printer for the report (call from a `claude` shell wrapper after the process exits)
- `_lib.py` — shared pricing, dedup, and session-filter helpers

## Session state

Per-session JSON lives at `~/.claude/thermostat/<session_id>.json`:

```json
{ "session_start": 1778825375, "turn_count": 15, "last_nag_turn": 15, "nag_count": 1 }
```

Safe to delete — recreated on next session.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `CLAUDE_THERMOSTAT_COST_CENTS` | `5000` | Cost setpoint (US cents, $50) |
| `CLAUDE_THERMOSTAT_TIME_SEC` | `0` | Session-age setpoint in seconds; `0` disables |
| `CLAUDE_THERMOSTAT_TURNS` | `0` | Turn-count setpoint; `0` disables |
| `CLAUDE_THERMOSTAT_CONTEXT_K` | `0` | Last-turn input-context setpoint (K tokens); `0` disables |
| `CLAUDE_THERMOSTAT_COOLDOWN_TURNS` | `10` | Deadband: turns between re-fires after first |
| `CLAUDE_THERMOSTAT_ANTIPATTERNS` | `1` | Set to `0` to disable antipattern detection |
| `CLAUDE_THERMOSTAT_CONFIG` | `~/.claude/thermostat/config.env` | Path to optional config file |

### Config file

Instead of (or in addition to) env vars, drop a shell-style config at `~/.claude/thermostat/config.env`. The hook sources it on every invocation, so values take effect immediately:

```sh
# ~/.claude/thermostat/config.env
CLAUDE_THERMOSTAT_COST_CENTS=3000     # fire at $30 instead of $50
CLAUDE_THERMOSTAT_COOLDOWN_TURNS=15
CLAUDE_THERMOSTAT_CONTEXT_K=120
```

The config file is sourced before defaults, so its values override any env vars in the calling environment. To temporarily override, edit the file or set `CLAUDE_THERMOSTAT_CONFIG=/dev/null` to skip it entirely.

## Wiring (`~/.claude/settings.json`)

```json
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "/abs/path/to/claude-thermostat/claude-thermostat.sh"
      }
    ]
  }
]
```

## Suggested actions the alert offers

- **`/compact`** — summarizes history and shrinks the context window. Best when the task is ongoing and context is large. Shown first when context is the trigger.
- **`/clear`** — wipes context entirely. Best when pivoting to a new sub-task.
- **`/model sonnet`** — shown when running Opus; Sonnet is 5× cheaper on both input and output.
- **Close and reopen** — fully new session, lowest cost baseline. Best when the current task is done.
- **Continue** — dismiss and keep going. The hook re-arms after `COOLDOWN_TURNS` more turns.

## Cooldown report

`cooldown-report.sh` runs once on `SessionEnd` and writes a markdown report to `~/.claude/thermostat/reports/<session_id>.md`, plus a one-line entry in `~/.claude/thermostat/reports.log`.

The report includes:

- Cost, duration, turn count, per-model breakdown, token totals
- **Cache hit %** — higher is cheaper; <40% suggests context churn (big auto-loading rules, frequent /clear)
- **Skill candidates** — files Read 3+ times, URLs WebFetched 2+ times, Grep patterns repeated 3+ times. These are reference material that should live in a skill.
- **Tool choice** — if Grep/Read/Glob dominated, suggests `mcp__auggie__codebase-retrieval` for natural-language lookups; if context grew large with no subagent use, suggests delegating.
- **Model choice** — if Opus dominated cost and produced many small outputs, flags downgrade candidates.
- **Prompt patterns** — many short prompts → suggests one-shot patterns per Anthropic's Opus 4.7 best-practices.
- Tool histogram for the session.

**Note:** The report filters to only the current session's turns using `session_start` from the thermostat hook's state file. If `claude-thermostat.sh` is not also enabled (i.e. no `Stop` hook), `session_start` will be 0 and the report will include all turns in the transcript file, potentially spanning multiple prior sessions.

Wire it up alongside the thermostat:

```json
"SessionEnd": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "/abs/path/to/claude-thermostat/cooldown-report.sh"
      }
    ]
  }
]
```

## Manual test

```bash
# First call: stamps state, exits 0
echo '{"session_id":"smoke","transcript_path":"/dev/null","stop_hook_active":false}' \
  | ./claude-thermostat.sh
cat ~/.claude/thermostat/smoke.json

# Backdate to force setpoints
python3 -c "
import json, os; p = os.path.expanduser('~/.claude/thermostat/smoke.json')
d = json.load(open(p)); d['session_start'] -= 2000; d['turn_count'] = 14
json.dump(d, open(p,'w'))
"

# Should fire and exit 2
echo '{"session_id":"smoke","transcript_path":"/dev/null","stop_hook_active":false}' \
  | ./claude-thermostat.sh 2>&1; echo "Exit: $?"

# Cleanup
rm ~/.claude/thermostat/smoke.json
```

## Design notes

- **Why `Stop` + exit 2** instead of `UserPromptSubmit`: the Stop event fires after Claude finishes, so the alert appears as Claude's next response asking the user what to do. Clean UX — the user sees the cost stats and can immediately type `/compact` or `/clear`.
- **Why transcript parsing**: time and turn count are proxies. Real token counts from the transcript give an actual cost estimate and — more importantly — the context window size, which determines whether `/compact` will meaningfully reduce future costs.
- **Why dedupe by `message.id`**: Claude Code re-appends the same assistant message on every tool round-trip — same `msg_xxx` id, same usage block. Billing-correct accounting treats each unique `message.id` as one API call, so we dedupe before summing input / cache-write / output. Cache-read is billed per request that hits cache, so it sums across the unique calls.
- **Why cooldown in turns, not seconds**: a session might idle for hours then become active again. Measuring cooldown by turns ensures the alert reappears after meaningful additional work, not just time passing.
- **Why `stop_hook_active` guard**: when this hook exits 2, Claude re-activates to relay the alert to the user. That triggers another Stop event. `stop_hook_active: true` in that second invocation prevents an infinite loop.
