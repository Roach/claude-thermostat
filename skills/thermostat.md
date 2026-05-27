---
name: thermostat
description: Show current Claude Code session cost, cache hit rate, context size, and turn count on demand — without waiting for a threshold to fire.
triggers:
  - /thermostat
  - show session cost
  - how much have I spent this session
  - what's my session cost
---

Run `thermostat-status.sh` using the Bash tool and report the output verbatim, then offer one sentence of context if anything looks notable (e.g. cache hit below 50%, context above 80K, a cache-drop warning in the output).

## Finding the script

Use this resolution order:
1. `$THERMOSTAT_DIR/thermostat-status.sh` if `THERMOSTAT_DIR` is set in the environment
2. `thermostat-status.sh` if it is in PATH
3. Search: `find "$HOME" -maxdepth 6 -name "thermostat-status.sh" -type f 2>/dev/null | head -1`

If the script cannot be found, tell the user to add the thermostat install directory to PATH or set `THERMOSTAT_DIR=/path/to/claude-thermostat` in their shell config.

## Installation

Copy this file (or symlink it) to `~/.claude/skills/thermostat.md`:

```bash
ln -s /path/to/claude-thermostat/skills/thermostat.md ~/.claude/skills/thermostat.md
```

Then invoke with `/thermostat` in any Claude Code session.
