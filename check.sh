#!/usr/bin/env bash
# Pre-commit checks. The hook in ~/.claude/settings.json points straight at
# this working tree, so a syntax error here breaks every turn of every
# session until it's fixed — worth catching before the commit, not after.
#
# Run directly, or wire it up with:  git config core.hooksPath .githooks
set -uo pipefail
cd "$(dirname "$0")"
fail=0
note() { printf '  %-8s %s\n' "$1" "$2"; }

echo "shell syntax"
for f in *.sh; do
  if bash -n "$f" 2>/dev/null; then note ok "$f"; else note FAIL "$f"; bash -n "$f"; fail=1; fi
done

echo "python syntax"
if /usr/bin/python3 -m py_compile _lib.py 2>/dev/null; then note ok "_lib.py"
else note FAIL "_lib.py"; /usr/bin/python3 -m py_compile _lib.py; fail=1; fi

echo "pricing table"
/usr/bin/python3 - <<'PY' || fail=1
import sys
sys.path.insert(0, '.')
from _lib import PRICING, DEFAULT_PRICING, _resolve_key

# Every model we expect to meet in a transcript must have its own entry.
# A miss silently bills it at DEFAULT_PRICING — that is how Opus 5 was
# costed at Sonnet rates across an entire corpus of reports. When a new
# model ships, add it here and to PRICING together.
CURRENT = [
    'claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7', 'claude-opus-4-6',
    'claude-opus-4-5', 'claude-sonnet-5', 'claude-sonnet-4-6',
    'claude-sonnet-4-5', 'claude-haiku-4-5', 'claude-fable-5-1',
    'claude-fable-5', 'claude-mythos-5-1', 'claude-mythos-5',
]
bad = 0
missing = [m for m in CURRENT if _resolve_key(m) is None]
if missing:
    print(f'  FAIL     unpriced (falls back to DEFAULT_PRICING): {", ".join(missing)}')
    bad = 1
else:
    print(f'  ok       all {len(CURRENT)} current models resolve')

wrong = [k for k, v in PRICING.items() if len(v) != 5]
if wrong or len(DEFAULT_PRICING) != 5:
    print(f'  FAIL     tuples must be 5-wide: {", ".join(wrong) or "DEFAULT_PRICING"}')
    bad = 1
else:
    print('  ok       all tuples 5-wide (input, cw_5m, cache_read, output, cw_1h)')

# Published multipliers: 5m write 1.25x input, 1h write 2x, cache read 0.1x
# (0.025x on Fable/Mythos 5.1). Catches a fat-fingered rate.
off = []
for k, (i, cw5, cr, o, cw1) in PRICING.items():
    if abs(cw5 - 1.25 * i) > 1e-9: off.append(f'{k} 5m write')
    if abs(cw1 - 2.00 * i) > 1e-9: off.append(f'{k} 1h write')
    mult = 0.025 if k.endswith('-5-1') else 0.1
    if abs(cr - mult * i) > 1e-9:  off.append(f'{k} cache read')
if off:
    print(f'  FAIL     rate does not match its multiplier: {", ".join(off)}')
    bad = 1
else:
    print('  ok       every rate matches its published multiplier')
sys.exit(bad)
PY

echo
if [ "$fail" -ne 0 ]; then echo "FAILED — commit aborted"; exit 1; fi
echo "all checks passed"
