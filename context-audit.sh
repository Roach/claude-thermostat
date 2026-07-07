#!/usr/bin/env bash
# context-audit: static audit of the always-on context surface.
#
# The cooldown report measures what a session *spent*; this measures what
# every session *starts with* — the config surface loaded before your first
# word: CLAUDE.md files, rules, skill/agent descriptions (the discovery tax),
# auto-memory index, and MCP server tool schemas. It runs against files, not
# transcripts, so you can trim the surface before paying for it.
#
# Usage:
#   ./context-audit.sh [project-dir]     # default: cwd
#
# Token counts are chars/4 estimates — good enough to rank and flag, not
# billing-accurate.

set -u

STATE_DIR="$HOME/.claude/thermostat"
REPORT_DIR="$STATE_DIR/reports"

PROJECT_DIR="${1:-$(pwd)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || {
  echo "error: cannot resolve project directory: $PROJECT_DIR" >&2
  exit 1
}

/usr/bin/python3 - "$PROJECT_DIR" "$REPORT_DIR" <<'PY'
import json, os, re, sys, glob

project_dir, report_dir = sys.argv[1], sys.argv[2]
home = os.path.expanduser('~')

def toks(n_chars):
    return n_chars // 4

def file_toks(path):
    try:
        return toks(len(open(path, encoding='utf-8', errors='replace').read()))
    except Exception:
        return 0

def frontmatter_field(path, field):
    """Return a frontmatter field's value from a markdown file, '' if absent."""
    try:
        text = open(path, encoding='utf-8', errors='replace').read()
    except Exception:
        return ''
    if not text.startswith('---'):
        return ''
    end = text.find('\n---', 3)
    if end < 0:
        return ''
    m = re.search(rf'^{field}:\s*(.+?)$', text[3:end], re.M)
    return m.group(1).strip() if m else ''

rows = []      # (label, tokens, note)
flags = []

# --- always-on markdown: global + project CLAUDE.md, rules, memory index ---
for label, path in [
    ('global CLAUDE.md',  os.path.join(home, '.claude', 'CLAUDE.md')),
    ('project CLAUDE.md', os.path.join(project_dir, 'CLAUDE.md')),
]:
    if os.path.isfile(path):
        t = file_toks(path)
        rows.append((label, t, path))
        if t > 5000:
            flags.append(f"`{path}` is ~{t:,} tokens of always-on context — move reference material into on-demand skills")

rules_dir = os.path.join(home, '.claude', 'rules')
if os.path.isdir(rules_dir):
    rule_files = sorted(glob.glob(os.path.join(rules_dir, '**', '*.md'), recursive=True))
    total = 0
    biggest = []
    for f in rule_files:
        t = file_toks(f)
        total += t
        biggest.append((t, f))
    if rule_files:
        rows.append((f"~/.claude/rules/ ({len(rule_files)} file(s))", total, ''))
        for t, f in sorted(biggest, reverse=True)[:3]:
            if t > 2000:
                flags.append(f"rule `{os.path.basename(f)}` is ~{t:,} tokens — rules load every session; big ones belong in skills")

# Auto-memory index for this project (MEMORY.md is loaded each session).
proj_slug = project_dir.replace('/', '-')
mem_index = os.path.join(home, '.claude', 'projects', proj_slug, 'memory', 'MEMORY.md')
if os.path.isfile(mem_index):
    rows.append(('auto-memory MEMORY.md', file_toks(mem_index), mem_index))

# --- discovery tax: skill and agent descriptions load every session, ---
# --- even when the skill/agent is never invoked.                      ---
DESC_LIMIT = 512   # chars; beyond this the description itself is bloat

def scan_descriptions(pattern, kind):
    total_chars, count = 0, 0
    for path in sorted(glob.glob(pattern)):
        name = os.path.basename(os.path.dirname(path)) if path.endswith('SKILL.md') \
               else os.path.splitext(os.path.basename(path))[0]
        desc = frontmatter_field(path, 'description')
        total_chars += len(desc)
        count += 1
        if len(desc) > DESC_LIMIT:
            flags.append(f"{kind} `{name}` description is {len(desc)} chars — every session pays this before the {kind} is ever used; tighten to one routing sentence")
    return count, toks(total_chars)

n_sk1, t_sk1 = scan_descriptions(os.path.join(home, '.claude', 'skills', '*', 'SKILL.md'), 'skill')
n_sk2, t_sk2 = scan_descriptions(os.path.join(home, '.claude', 'skills', '*.md'), 'skill')
if n_sk1 + n_sk2:
    rows.append((f"skill descriptions ({n_sk1 + n_sk2} skill(s))", t_sk1 + t_sk2, ''))

n_ag, t_ag = scan_descriptions(os.path.join(home, '.claude', 'agents', '*.md'), 'agent')
if n_ag:
    rows.append((f"agent descriptions ({n_ag} agent(s))", t_ag, ''))

# --- MCP servers: configured everywhere vs actually used in recent reports ---
configured = set()
claude_json = os.path.join(home, '.claude.json')
try:
    cj = json.load(open(claude_json))
    configured.update(cj.get('mcpServers', {}) or {})
    proj_cfg = (cj.get('projects', {}) or {}).get(project_dir, {})
    configured.update(proj_cfg.get('mcpServers', {}) or {})
except Exception:
    pass
mcp_json = os.path.join(project_dir, '.mcp.json')
try:
    configured.update(json.load(open(mcp_json)).get('mcpServers', {}) or {})
except Exception:
    pass

# Used servers, from the tool histograms of the most recent cooldown reports.
used = set()
reports = sorted(glob.glob(os.path.join(report_dir, '*.md')),
                 key=os.path.getmtime, reverse=True)[:15]
for rp in reports:
    try:
        for line in open(rp, encoding='utf-8', errors='replace'):
            m = re.match(r'\|\s*mcp__([^_|]+(?:_[^_|]+)*?)__', line)
            if m:
                used.add(m.group(1))
    except Exception:
        pass

if configured:
    rows.append((f"MCP servers configured ({len(configured)})",
                 0, ', '.join(sorted(configured))))
    idle = configured - used
    if idle and len(reports) >= 5:
        flags.append(
            f"MCP server(s) configured but unused across the last {len(reports)} sessions: "
            f"{', '.join(sorted(idle))} — each loads its tool schemas into every session; "
            f"disable with `/mcp` or remove from config if retired"
        )

# --- render ---
always_on = sum(t for _, t, _ in rows)
print(f"━━━ context-audit ━━━  {project_dir}")
print()
print(f"Always-on surface (loaded before your first prompt): ~{always_on:,} tokens")
print("(compare with the 'Session-start overhead' line in your cooldown reports,")
print(" which also includes MCP tool schemas and harness overhead)")
print()
for label, t, note in sorted(rows, key=lambda r: -r[1]):
    extra = f"  ({note})" if note and t else (f"  {note}" if note else "")
    print(f"  {t:>7,}  {label}{extra}" if t else f"        -  {label}{extra}")
print()
if always_on > 20_000:
    flags.insert(0, f"Total always-on surface is ~{always_on:,} tokens — every session re-caches this and every turn re-reads it")
if flags:
    print("Flags:")
    for f in flags:
        print(f"  • {f}")
else:
    print("No flags — the always-on surface looks lean.")
print('━' * 60)
PY
