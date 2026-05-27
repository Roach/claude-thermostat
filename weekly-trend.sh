#!/usr/bin/env bash
# weekly-trend: 7-day cost and antipattern trend from cooldown reports.
#
# Reads ~/.claude/thermostat/reports.log and the individual report files it
# points to, then prints a day-by-day summary of sessions, cost, turns, and
# recurring suggestion categories — turning per-session cooldown reports into
# a longitudinal view.
#
# Usage:
#   weekly-trend.sh              # last 7 days (default)
#   weekly-trend.sh 14           # last N days
#   weekly-trend.sh --markdown   # emit GitHub-flavored markdown instead of plain text

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export THERMOSTAT_LIB_DIR="$SCRIPT_DIR"

DAYS=7
FORMAT="plain"
for arg in "$@"; do
  case "$arg" in
    --markdown|-m) FORMAT="markdown" ;;
    [0-9]*) DAYS="$arg" ;;
  esac
done

/usr/bin/python3 - "$HOME/.claude/thermostat" "$DAYS" "$FORMAT" <<'PY'
import glob, json, os, re, sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

state_dir = sys.argv[1]
days      = int(sys.argv[2]) if len(sys.argv) > 2 else 7
fmt       = sys.argv[3] if len(sys.argv) > 3 else 'plain'

log_path = os.path.join(state_dir, 'reports.log')
if not os.path.exists(log_path):
    print("No reports.log found at", log_path)
    print("Run at least one session with cooldown-report.sh wired to SessionEnd.")
    sys.exit(0)

# Log line format (see docs/report-format.md):
#   ISO_TIMESTAMP  SESSION_PREFIX  $COST  NUMt  N suggestion(s)  -> REPORT_PATH
LOG_RE = re.compile(
    r'^(?P<ts>\S+)\s+'
    r'(?P<sid>\S+)\s+'
    r'\$(?P<cost>[\d.]+)\s+'
    r'(?P<turns>\d+)t\s+'
    r'(?P<nsugg>\d+) suggestion.*?->\s*(?P<path>.+)$'
)

# Suggestion section headers from cooldown reports (see docs/report-format.md).
SUGG_SECTIONS = {
    'Model choice':            'model',
    'New skills to consider':  'skill',
    'Better tool choices':     'tool',
    'Context hygiene':         'context',
    'Prompt patterns':         'prompt',
}

cutoff = datetime.now(tz=timezone.utc) - timedelta(days=days)

# Parse log and bucket by calendar day (local time).
# Each entry: {'ts', 'sid', 'cost', 'turns', 'nsugg', 'path'}
entries = []
with open(log_path, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        m = LOG_RE.match(line)
        if not m:
            continue
        try:
            ts = datetime.fromisoformat(m.group('ts').replace('Z', '+00:00'))
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
        except Exception:
            continue
        if ts < cutoff:
            continue
        entries.append({
            'ts':    ts,
            'sid':   m.group('sid'),
            'cost':  float(m.group('cost')),
            'turns': int(m.group('turns')),
            'nsugg': int(m.group('nsugg')),
            'path':  m.group('path').strip(),
        })

if not entries:
    print(f"No sessions in the last {days} days.")
    sys.exit(0)

def suggestion_categories(report_path):
    """Parse a cooldown report markdown file and return a list of category keys."""
    cats = []
    if not os.path.exists(report_path):
        return cats
    try:
        with open(report_path, encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if not line.startswith('###'):
                    continue
                header = line.lstrip('#').strip()
                if header in SUGG_SECTIONS:
                    cats.append(SUGG_SECTIONS[header])
    except Exception:
        pass
    return cats

# Group entries by local date.
by_day = defaultdict(list)
for e in entries:
    day = e['ts'].astimezone().date().isoformat()
    by_day[day].append(e)

# Global counters for the summary line.
global_cost  = 0.0
global_turns = 0
global_sessions = 0
global_cats = Counter()

rows = []
for day in sorted(by_day.keys(), reverse=True):
    day_entries = by_day[day]
    day_cost    = sum(e['cost']  for e in day_entries)
    day_turns   = sum(e['turns'] for e in day_entries)
    day_cats    = Counter()
    for e in day_entries:
        for c in suggestion_categories(e['path']):
            day_cats[c] += 1
    top_cats = ', '.join(f"{k}({v})" for k, v in day_cats.most_common(3)) or '—'
    rows.append((day, len(day_entries), day_cost, day_turns, top_cats))
    global_cost     += day_cost
    global_turns    += day_turns
    global_sessions += len(day_entries)
    global_cats.update(day_cats)

overall_cats = ', '.join(f"{k}({v})" for k, v in global_cats.most_common(5)) or '—'

# --- output ------------------------------------------------------------------

today = datetime.now().date().isoformat()

if fmt == 'markdown':
    print(f"# thermostat weekly trend — {days} days ending {today}")
    print()
    print(f"| Date | Sessions | Cost | Turns | Top suggestions |")
    print(f"|---|---:|---:|---:|---|")
    for day, n, cost, turns, cats in rows:
        print(f"| {day} | {n} | ${cost:.2f} | {turns} | {cats} |")
    print()
    print(f"**Total:** {global_sessions} sessions · ${global_cost:.2f} · {global_turns} turns")
    if global_cats:
        print(f"**Recurring:** {overall_cats}")
else:
    print(f"thermostat weekly trend · {days} days ending {today}")
    print()
    col_w = [10, 9, 8, 6, 40]
    header = (f"{'Date':<{col_w[0]}}  {'Sessions':>{col_w[1]}}  {'Cost':>{col_w[2]}}"
              f"  {'Turns':>{col_w[3]}}  Top suggestions")
    print(header)
    print('─' * (sum(col_w) + 8))
    for day, n, cost, turns, cats in rows:
        print(f"{day:<{col_w[0]}}  {n:>{col_w[1]}}  "
              f"${cost:<{col_w[2]-1}.2f}  {turns:>{col_w[3]}}  {cats}")
    print('─' * (sum(col_w) + 8))
    print(f"{'Total':<{col_w[0]}}  {global_sessions:>{col_w[1]}}  "
          f"${global_cost:<{col_w[2]-1}.2f}  {global_turns:>{col_w[3]}}")
    if global_cats:
        print()
        print(f"Recurring suggestions: {overall_cats}")
PY
