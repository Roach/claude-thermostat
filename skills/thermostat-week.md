---
name: thermostat-week
description: Show a 7-day (or N-day) trend of Claude Code session cost, turns, and recurring antipattern categories from cooldown reports.
triggers:
  - /thermostat-week
  - show weekly AI cost
  - show session cost trend
  - what did I spend on Claude this week
---

Run `weekly-trend.sh` (with optional day count or `--markdown` flag from the user's request) using the Bash tool and report the output. If the user asked for markdown output, pass `--markdown`. If they asked for a specific number of days, pass that number.

## Finding the script

Use this resolution order:
1. `$THERMOSTAT_DIR/weekly-trend.sh` if `THERMOSTAT_DIR` is set in the environment
2. `weekly-trend.sh` if it is in PATH
3. Search: `find "$HOME" -maxdepth 6 -name "weekly-trend.sh" -type f 2>/dev/null | head -1`

## After the output

After printing the trend table, highlight:
- Days with notably high cost compared to the period average
- Any suggestion category that appears on 50%+ of session days
- Total cost for the period vs a rough weekly budget if the user has one configured

## Installation

```bash
ln -s /path/to/claude-thermostat/skills/thermostat-week.md ~/.claude/skills/thermostat-week.md
```
