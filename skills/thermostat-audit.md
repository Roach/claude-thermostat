---
name: thermostat-audit
description: Audit the always-on Claude Code context surface — CLAUDE.md files, rules, skill/agent descriptions, MCP servers — and flag config bloat before any session pays for it.
triggers:
  - /thermostat-audit
  - audit my claude config
  - what is my session-start overhead made of
  - why is my session-start context so big
---

Run `context-audit.sh` using the Bash tool (pass the current project directory as the argument) and report the output verbatim. Then, if there are flags, offer to apply the top one — e.g. tightening an oversized skill description, moving a large rule into an on-demand skill, or removing an idle MCP server.

## Finding the script

Use this resolution order:
1. `$THERMOSTAT_DIR/context-audit.sh` if `THERMOSTAT_DIR` is set in the environment
2. `context-audit.sh` if it is in PATH
3. Search: `find "$HOME" -maxdepth 6 -name "context-audit.sh" -type f 2>/dev/null | head -1`

If the script cannot be found, tell the user to add the thermostat install directory to PATH or set `THERMOSTAT_DIR=/path/to/claude-thermostat` in their shell config.

## Interpreting the output

- **Always-on surface** is what every session loads before the first prompt. It is the controllable part of the "Session-start overhead" number in cooldown reports (the rest is MCP tool schemas and harness overhead the audit can only name, not size).
- **Skill/agent descriptions** load every session even if the skill is never invoked — the body only loads on use. A description over ~512 chars is paying a discovery tax for routing information that should fit in one sentence.
- **MCP servers configured but unused** are cross-referenced against the tool histograms of the last 15 cooldown reports; the flag only fires with at least 5 reports of history.

## Installation

Copy this file (or symlink it) to `~/.claude/skills/thermostat-audit.md`:

```bash
ln -s /path/to/claude-thermostat/skills/thermostat-audit.md ~/.claude/skills/thermostat-audit.md
```

Then invoke with `/thermostat-audit` in any Claude Code session.
