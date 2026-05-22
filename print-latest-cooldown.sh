#!/usr/bin/env bash
# Print a cooldown-report to the terminal.
#
# Designed to be called from a `claude` shell wrapper *after* the claude
# process exits — at that point stderr/stdout reach the user's terminal,
# unlike a SessionEnd hook which runs after the session UI is gone.
#
# Usage:
#   print-latest-cooldown.sh [path]
#     path  explicit report file to print (set by the wrapper before claude runs)
#     (no args)  fall back to newest .md in REPORT_DIR within MAX_AGE_SEC

set -u

REPORT_DIR="$HOME/.claude/thermostat/reports"
MAX_AGE_SEC="${CLAUDE_COOLDOWN_MAX_AGE:-120}"

# Prefer an explicitly passed path (wrapper knows exactly which file it made).
if [ -n "${1:-}" ]; then
  if [ ! -f "$1" ]; then
    printf '\033[2m  cooldown-report: none was generated for this session\033[0m\n' >&2
    exit 0
  fi
  latest="$1"
else
  [ -d "$REPORT_DIR" ] || exit 0
  latest="$(/bin/ls -t "$REPORT_DIR"/*.md 2>/dev/null | head -1)"
  [ -z "$latest" ] && exit 0
  now=$(date +%s)
  mtime=$(/usr/bin/stat -f %m "$latest" 2>/dev/null || /usr/bin/stat -c %Y "$latest" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  [ "$age" -gt "$MAX_AGE_SEC" ] && exit 0
fi

/usr/bin/python3 - "$latest" <<'PY'
import sys, re

BOLD = "\033[1m"
DIM  = "\033[2m"
CYAN = "\033[1;36m"
YEL  = "\033[1;33m"
RST  = "\033[0m"

def strip_inline(s):
    s = re.sub(r'\*\*(.+?)\*\*', lambda m: BOLD + m.group(1) + RST, s)
    s = re.sub(r'(?<![A-Za-z0-9_])_([^_\n]+?)_(?![A-Za-z0-9_])', r'\1', s)
    s = re.sub(r'`(.+?)`', r'\1', s)
    return s

lines = open(sys.argv[1]).read().splitlines()
i = 0
while i < len(lines):
    line = lines[i]
    if i == 0:                          # drop H1 title line
        i += 1; continue
    if line.startswith('## '):
        print(f"\n{CYAN}{line[3:]}{RST}")
    elif line.startswith('### '):
        print(f"  {YEL}{line[4:]}{RST}")
    elif line.startswith('- '):
        print(f"  • {strip_inline(line[2:])}")
    elif line.startswith('|'):
        # Collect table rows, skip separator lines (---|---).
        rows = []
        while i < len(lines) and lines[i].startswith('|'):
            if not re.match(r'^\|[-| :]+\|$', lines[i]):
                rows.append([c.strip() for c in lines[i].strip('|').split('|')])
            i += 1
        if rows:
            ncols = max(len(r) for r in rows)
            rows = [r + [''] * (ncols - len(r)) for r in rows]
            widths = [max(len(r[c]) for r in rows) for c in range(ncols)]
            for r in rows:
                parts = []
                for c, cell in enumerate(r):
                    # right-align numeric-looking cells
                    if c > 0 and re.match(r'^\$?\d[\d,]*(\.\d+)?$', cell):
                        parts.append(cell.rjust(widths[c]))
                    else:
                        parts.append(cell.ljust(widths[c]))
                print("  " + "  ".join(parts).rstrip())
        continue
    else:
        txt = strip_inline(line)
        print(txt)
    i += 1

print(f"\n{DIM}  Full report: {sys.argv[1]}{RST}")
PY
