---
name: thermostat-project
description: Aggregate cooldown reports for the current project across all sessions and produce a project-level audit — recurring skill candidates, bash patterns, structural gaps, cost summary.
triggers:
  - /thermostat-project
  - project audit
  - audit this project's sessions
  - what skills should I build for this project
---

Run `project-audit.sh` for the current project directory (or one the user specifies) using the Bash tool, passing `--write` if the user asked to save the report.

## Finding the script

Use this resolution order:
1. `$THERMOSTAT_DIR/project-audit.sh` if `THERMOSTAT_DIR` is set in the environment
2. `project-audit.sh` if it is in PATH
3. Search: `find "$HOME" -maxdepth 6 -name "project-audit.sh" -type f 2>/dev/null | head -1`

## Determining the project directory

- If the user's request names a project or path, use that.
- Otherwise, use the current working directory (`pwd`).

## Running the audit

```bash
# stdout is the report; stderr shows write confirmation when --write is passed
<script> [project-dir] [--write]
```

## After the output

After printing the audit report, highlight:
- Any files that appear as skill candidates across 2+ sessions (strongest signal)
- Structural gaps that are quick fixes (missing CLAUDE.md, commands directory)
- The suggestion category that dominates across sessions
- A concrete next action — e.g. "Create a skill for X" or "Add a CLAUDE.md"

## Installation

```bash
ln -s /path/to/claude-thermostat/skills/thermostat-project.md ~/.claude/skills/thermostat-project.md
```
