---
name: deterministic-toolkit
description: Route mechanical data work — parsing, format conversion, deduping, aggregating, validating, diffing — to small scripts instead of doing it inline in the model's output.
triggers:
  - /deterministic-toolkit
  - convert this data
  - dedupe these records
  - reformat this file
  - aggregate these rows
---

When the task is mechanical transformation of data — not judgment about it — write a small script, run it, and report the result. Do not perform the transformation row-by-row in your own output.

## When this applies

Any of these, once the input exceeds roughly 20 rows or ~1K tokens:

- Parsing or converting formats (JSON ↔ CSV ↔ YAML, log extraction, column reshaping)
- Deduplicating, sorting, joining, or grouping records
- Aggregating (sums, counts, percentiles, histograms)
- Validating structure (schema checks, required fields, referential integrity)
- Diffing two datasets or file trees
- Bulk renames, search-and-replace across many files

## How to work

1. Write the script to the session scratchpad (or the project's `scripts/` dir if the user wants it kept), in whatever language the project already uses — default to python or a shell one-liner.
2. Run it on the real input; never on a retyped copy of the input.
3. Verify mechanically: row counts in vs out, checksums, or a spot-check the script itself prints. State the verification in your summary.
4. Report the result and the script path — not the transformed data inline, unless it is small enough to read at a glance.

## Why

In-context transformation bills every row as output tokens, degrades over long inputs, and is not reproducible. A script is cheaper by 50–90% on data-heavy tasks, deterministic, and re-runnable when the input changes. The model's job is deciding *what* transformation is right; the script's job is applying it.

## Installation

Copy this file (or symlink it) to `~/.claude/skills/deterministic-toolkit.md`:

```bash
ln -s /path/to/claude-thermostat/skills/deterministic-toolkit.md ~/.claude/skills/deterministic-toolkit.md
```

The cooldown report's "inline deterministic work" detector points at this skill when it fires.
