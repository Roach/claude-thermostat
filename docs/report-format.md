# Report format reference

This document specifies the format of thermostat's two output artifacts:
`reports.log` (the append-only index) and individual cooldown report files
(markdown). Both are considered stable — scripts and scheduled agents can
parse them without coordinating with the thermostat maintainer.

## Stability policy

Fields marked **stable** will not change in a breaking way without a version
bump in this document. Fields marked **informational** may gain additional
values or formatting over time; parsers should handle unknown values
gracefully.

---

## `reports.log`

Location: `~/.claude/thermostat/reports.log`

One line per completed session (written by `cooldown-report.sh` on
`SessionEnd`). Lines are appended in wall-clock order.

### Line format

```
ISO_TIMESTAMP  SESSION_PREFIX  $COST  TURNSt  N suggestion(s)  -> REPORT_PATH
```

| Field | Type | Stable | Description |
|---|---|---|---|
| `ISO_TIMESTAMP` | ISO 8601 datetime, seconds precision, no TZ suffix | yes | Local time when the session ended |
| `SESSION_PREFIX` | 8-char hex string | yes | First 8 characters of the session UUID |
| `$COST` | `$NNN.NN` (US dollars, 2 decimal places) | yes | Estimated session cost at the configured `COST_MODE` |
| `TURNSt` | integer + literal `t` | yes | Number of completed user↔assistant turns |
| `N suggestion(s)` | integer + literal ` suggestion(s)` | yes | Count of cost-reduction suggestions in the report |
| `REPORT_PATH` | absolute file path | yes | Path to the full cooldown report markdown file |

Fields are separated by two or more spaces. A regex that matches the stable
fields:

```python
LOG_RE = re.compile(
    r'^(?P<ts>\S+)\s+'
    r'(?P<sid>\S+)\s+'
    r'\$(?P<cost>[\d.]+)\s+'
    r'(?P<turns>\d+)t\s+'
    r'(?P<nsugg>\d+) suggestion.*?->\s*(?P<path>.+)$'
)
```

### Example

```
2026-05-26T14:33:01  a1b2c3d4  $3.12  18t  2 suggestion(s)  -> /Users/you/.claude/thermostat/reports/a1b2c3d4-....md
```

---

## Cooldown report files

Location: `~/.claude/thermostat/reports/<session_id>.md`

Written by `cooldown-report.sh` and referenced from `reports.log`. Each file
is a standalone markdown document.

### Top-level metadata block

The report opens with an H1 heading followed by a bulleted metadata block:

```markdown
# Cooldown report — <SESSION_ID>

- **Ended:** <ISO_DATETIME>  (reason: <REASON>)
- **Duration:** <N> min
- **Turns:** <N>
- **Cost:** $<N.NN>  _— <COST_MODE_LABEL>_
- **By model:** <MODEL>=<$COST>, ...
- **Tokens:** in=<N> cache_write=<N> cache_read=<N> out=<N>
  - <MODEL>: in=<N> cache_write=<N> cache_read=<N> out=<N>
               ← one line per model, only present when 2+ models were used
- **Cache hit:** <N>%  (<hint>; <threshold note>)
- **Session-start overhead:** <N>K tokens loaded before the first prompt
               ← omitted when the first API call couldn't be identified
- **Compactions:** <N> (context was summarized mid-session)
               ← only present when the session auto-compacted
- **Window:** ~<N> tokens in the last <N>h (local approximation; see notes)
               ← only present when CLAUDE_THERMOSTAT_WINDOW_TOKENS is set
```

All fields in the metadata block are **stable**. The `reason` value
(informational) reflects why the session ended (e.g. `exit`, `clear`,
`unknown`).

### Suggestion sections

When inefficiencies were detected:

```markdown
## Cost-reduction suggestions for next session

### <CATEGORY_HEADING>
- <suggestion text>
- ...
```

The eight category headings are **stable**:

| Heading | Meaning |
|---|---|
| `Model choice` | A premium-tier model (Opus/Fable) used on turns that Sonnet or Haiku would have handled |
| `New skills to consider` | Reference/config files (`.md`, `.yaml`, `.json`, etc.) re-read 3+ times; skill candidates |
| `Better search tool for source files` | Source code files (`.py`, `.ts`, `.js`, `.go`, etc.) re-read 3+ times; use `mcp__auggie__codebase-retrieval` instead |
| `Better tool choices` | Grep/Read chains that Auggie or a subagent would replace; repeated failed tool calls |
| `Context hygiene` | Low cache hit rate, model switches, large context, session-start overhead, post-compact re-reads |
| `Cache economics` | Cache expirations from idle gaps longer than the 5-minute TTL |
| `Prompt patterns` | Short prompt chains, clarification-loop patterns |
| `Pricing changes` | Upcoming rate flips (e.g. introductory pricing ending) |

When no inefficiencies are detected:

```markdown
## Cost-reduction suggestions
_No notable inefficiencies detected — this session looked efficient._
```

### Tool histogram

```markdown
## Tool histogram

| Tool | Calls |
|---|---:|
| Bash | 42 |
| Read | 31 |
...
```

The histogram is **informational** — tool names and counts may vary.

### Subscription-window caveats block

Only present when `CLAUDE_THERMOSTAT_WINDOW_TOKENS` is configured.
Heading is `## Subscription-window approximation — caveats`. **Informational.**

---

## Parsing recommendations

- Parse `reports.log` with the regex above; ignore lines that don't match
  (blank lines, future header lines).
- When reading individual reports for suggestion categories, match on
  `line.startswith('### ')` and compare the heading text to the six stable
  category names. Ignore unknown `###` headings.
- Never parse the free-text suggestion bullets for structured data — they are
  human-readable prose and will change as the suggestion logic evolves.
- The `**Cost:**` metadata field always uses the configured `COST_MODE`.
  Use `**Tokens:**` fields for mode-independent quota accounting.
