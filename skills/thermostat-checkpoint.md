---
name: thermostat-checkpoint
description: Checkpoint a long session — commit and push completed work, then write a handoff primer (decisions, dead ends, open questions, continuation prompt) so a fresh session can continue cheaply.
triggers:
  - /thermostat-checkpoint
  - checkpoint this session
  - hand off this session
  - wrap up and start fresh
---

The thermostat alert (or the user) has decided this session should end and a fresh one should continue the work. Produce a checkpoint in two steps.

## Step 1 — commit completed work

If the working tree has changes that belong to finished work, commit and push them (on the current branch; create a branch first if on a protected default branch and the work is unreviewed). Leave genuinely unfinished edits uncommitted and list them in the primer instead. Never commit half-applied changes just to make the tree clean.

## Step 2 — write the handoff primer

Write the primer to `.claude-checkpoint.md` in the project root (overwrite if present) with exactly these sections. Capture **decisions and dead ends, not activity** — the next session can read git history for what changed; it cannot recover *why*.

```markdown
# Session checkpoint — <date>

## State
<one paragraph: what was the goal, where things stand, what is pushed vs uncommitted>

## Decisions made
- <decision> — <why, in one clause>

## Dead ends (do not retry)
- <approach that failed> — <why it failed>

## Open questions (highest value first)
1. <question the next session must answer>

## Relevant files
- `path` — <why it matters>

## Continuation prompt
<a single copy-paste prompt that starts the next session: goal, pointer to
this file, and the first concrete action>
```

Then print the continuation prompt in the conversation so the user can copy it directly, and remind them: start the new session, paste the prompt, and delete `.claude-checkpoint.md` once the new session has absorbed it (or add it to `.gitignore` if they want it ephemeral).

## Why this shape

Git history carries *what changed* forward for free; the primer carries the three things git cannot: decisions with their reasons, dead ends so they are not re-explored at full price, and open questions ranked by value. This is what makes the fresh session cheaper than continuing on a compacted transcript.

## Installation

Copy this file (or symlink it) to `~/.claude/skills/thermostat-checkpoint.md`:

```bash
ln -s /path/to/claude-thermostat/skills/thermostat-checkpoint.md ~/.claude/skills/thermostat-checkpoint.md
```

Then invoke with `/thermostat-checkpoint` when an alert fires or a work chunk completes.
