#!/usr/bin/env bash
# project-audit: aggregate cooldown reports across sessions that touched a project.
#
# Reads ~/.claude/thermostat/reports.log, matches sessions whose report path
# includes the project basename, then cross-references the individual report
# files to surface recurring skill candidates, bash patterns, structural gaps,
# a cost summary, and top antipatterns.
#
# Usage:
#   ./project-audit.sh [project-dir]          # default: cwd
#   ./project-audit.sh ~/projects/phish       # specific project
#   ./project-audit.sh ~/projects/phish --write  # write to file + log entry

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export THERMOSTAT_LIB_DIR="$SCRIPT_DIR"

STATE_DIR="$HOME/.claude/thermostat"
REPORT_DIR="$STATE_DIR/reports"
LOG="$STATE_DIR/reports.log"
AUDIT_LOG="$STATE_DIR/project-audits.log"

# --- args ---
PROJECT_DIR=""
DO_WRITE=0
for arg in "$@"; do
  case "$arg" in
    --write) DO_WRITE=1 ;;
    *) PROJECT_DIR="$arg" ;;
  esac
done
[ -z "$PROJECT_DIR" ] && PROJECT_DIR="$(pwd)"
# Resolve to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || {
  echo "error: cannot resolve project directory: $PROJECT_DIR" >&2
  exit 1
}

[ -f "$LOG" ] || { echo "No reports.log found at $LOG — no sessions to analyze." >&2; exit 0; }

/usr/bin/python3 - "$PROJECT_DIR" "$LOG" "$REPORT_DIR" "$DO_WRITE" "$AUDIT_LOG" <<'PY'
import os, sys, re
from collections import Counter, defaultdict
from datetime import datetime

project_dir  = sys.argv[1]
log_file     = sys.argv[2]
report_dir   = sys.argv[3]
do_write     = sys.argv[4] == '1'
audit_log    = sys.argv[5]

project_name = os.path.basename(project_dir.rstrip('/'))

# ── parse reports.log ──────────────────────────────────────────────────────
# format: 2026-05-29T16:21:10  3e027a8c  $16.30  37t  0 suggestion(s)  -> /path/to/report.md
LOG_RE = re.compile(
    r'^(?P<ts>\S+)\s+'
    r'(?P<sid>\S+)\s+'
    r'\$(?P<cost>[\d.]+)\s+'
    r'(?P<turns>\d+)t\s+'
    r'(?P<nsugg>\d+) suggestion\(s\)\s+'
    r'->\s+(?P<path>.+)$'
)

# Two-pass matching:
#   Pass 1: collect all log entries, dedup to latest entry per report path
#   Pass 2: match against project — report path contains project name/dir, OR
#            the report file content references the project dir
#
# This handles the common case where report paths are UUID filenames (no project
# name), but skill-candidate lines inside the report contain full file paths.
all_candidates = {}  # report_path -> dict (keeps last/highest-cost entry)
with open(log_file, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        m = LOG_RE.match(line)
        if not m:
            continue
        rpath = m.group('path').strip()
        entry = {
            'ts':     m.group('ts'),
            'sid':    m.group('sid'),
            'cost':   float(m.group('cost')),
            'turns':  int(m.group('turns')),
            'nsugg':  int(m.group('nsugg')),
            'path':   rpath,
        }
        if rpath not in all_candidates or entry['cost'] >= all_candidates[rpath]['cost']:
            all_candidates[rpath] = entry

def _report_references_project(rpath, proj_dir, proj_name):
    """Return True if the report file contains a reference to the project."""
    if not os.path.isfile(rpath):
        return False
    try:
        with open(rpath, encoding='utf-8', errors='replace') as f:
            content = f.read()
        return proj_dir in content or ('/' + proj_name + '/') in content
    except Exception:
        return False

seen_paths = {}
for rpath, entry in all_candidates.items():
    # Path-level match (project name in the report file path)
    path_match = (project_name.lower() in rpath.lower()
                  or project_dir.lower() in rpath.lower())
    # Content-level match (project dir appears inside the report file)
    content_match = (not path_match
                     and int(entry.get('nsugg', 0)) > 0
                     and _report_references_project(rpath, project_dir, project_name))
    if path_match or content_match:
        seen_paths[rpath] = entry

project_entries = list(seen_paths.values())
project_entries.sort(key=lambda e: e['ts'])

if not project_entries:
    print(f"No sessions found for project '{project_name}' in {log_file}")
    print(f"Sessions are matched by project name/path appearing in the report path or content.")
    sys.exit(0)

# ── read each cooldown report and extract suggestions ──────────────────────
# Section headings we look for (from cooldown-report.sh):
#   ### New skills to consider
#   ### Better tool choices
#   ### Model choice
#   ### Prompt patterns
#   ### Context hygiene
#   ## Configuration tuning

SECTION_RE = re.compile(r'^#{1,3}\s+(.+)$')
SKILL_ITEM_RE = re.compile(r'^-\s+Read\s+`([^`]+)`\s+(\d+)×')
BASH_ITEM_RE  = re.compile(r'^-\s+Bash\s+`([^`]+)`\s+ran\s+(\d+)×')

# Per-session data keyed by report_path
session_skills  = defaultdict(list)   # path -> [(file, count)]
session_bash    = defaultdict(list)   # path -> [(cmd_snippet, count)]
session_kinds   = defaultdict(set)    # path -> {kind, ...}  (from section headings)
session_config  = defaultdict(list)   # path -> [config suggestion lines]

for entry in project_entries:
    rpath = entry['path']
    if not os.path.isfile(rpath):
        continue
    current_section = None
    with open(rpath, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip()
            sm = SECTION_RE.match(line)
            if sm:
                current_section = sm.group(1).lower()
                continue
            if current_section and line.startswith('- '):
                if 'new skills to consider' in current_section:
                    km = SKILL_ITEM_RE.match(line)
                    if km:
                        session_skills[rpath].append((km.group(1), int(km.group(2))))
                    session_kinds[rpath].add('skill')
                elif 'prompt patterns' in current_section:
                    bm = BASH_ITEM_RE.match(line)
                    if bm:
                        session_bash[rpath].append((bm.group(1)[:80], int(bm.group(2))))
                    session_kinds[rpath].add('prompt')
                elif 'better tool choices' in current_section:
                    session_kinds[rpath].add('tool')
                elif 'model choice' in current_section:
                    session_kinds[rpath].add('model')
                elif 'context hygiene' in current_section:
                    session_kinds[rpath].add('context')
                elif 'configuration tuning' in current_section:
                    if line.strip() not in ('_Based on patterns across your recent sessions:_',):
                        session_config[rpath].append(line[2:].strip())

# ── aggregate skill candidates across sessions ─────────────────────────────
# file -> {session_count, total_read_count}
skill_sessions = defaultdict(set)   # file -> set of report paths
skill_reads    = Counter()          # file -> sum of read counts

for rpath, items in session_skills.items():
    for fname, cnt in items:
        skill_sessions[fname].add(rpath)
        skill_reads[fname] += cnt

recurring_skills = [
    (f, len(skill_sessions[f]), skill_reads[f])
    for f in skill_sessions
    if len(skill_sessions[f]) >= 2
]
recurring_skills.sort(key=lambda x: (-x[1], -x[2]))

# Single-session skill candidates (informational)
single_skills = [
    (f, 1, skill_reads[f])
    for f in skill_sessions
    if len(skill_sessions[f]) == 1
]
single_skills.sort(key=lambda x: -x[2])

# ── aggregate bash patterns ────────────────────────────────────────────────
bash_sessions = defaultdict(set)
bash_runs     = Counter()

for rpath, items in session_bash.items():
    for snippet, cnt in items:
        bash_sessions[snippet].add(rpath)
        bash_runs[snippet] += cnt

recurring_bash = [
    (s, len(bash_sessions[s]), bash_runs[s])
    for s in bash_sessions
    if len(bash_sessions[s]) >= 2
]
recurring_bash.sort(key=lambda x: (-x[1], -x[2]))

# ── structural gaps ────────────────────────────────────────────────────────
gaps = []
claudeignore = os.path.join(project_dir, '.claudeignore')
claude_md    = os.path.join(project_dir, 'CLAUDE.md')
commands_dir = os.path.join(project_dir, '.claude', 'commands')
settings_json= os.path.join(project_dir, '.claude', 'settings.json')

if not os.path.exists(claudeignore):
    gaps.append('`.claudeignore` missing — add one to exclude build artifacts, `.git/`, large generated files from context')
if not os.path.exists(claude_md):
    gaps.append('`CLAUDE.md` missing — project-level instructions (key files, patterns, conventions) loaded automatically into every session')
if not os.path.isdir(commands_dir):
    gaps.append('`.claude/commands/` directory missing — store project-specific slash commands here (e.g. `/deploy`, `/test`, `/lint`)')
if os.path.isfile(settings_json):
    import json
    try:
        sj = json.load(open(settings_json))
        if 'permissions' not in sj:
            gaps.append('`.claude/settings.json` has no `permissions` key — add an `allow` list for common project tools to reduce permission prompts')
    except Exception:
        pass

# ── cost summary ──────────────────────────────────────────────────────────
total_cost  = sum(e['cost'] for e in project_entries)
total_turns = sum(e['turns'] for e in project_entries)
n_sessions  = len(project_entries)
avg_cost    = total_cost / n_sessions if n_sessions else 0
dates       = [e['ts'][:10] for e in project_entries]
date_first  = min(dates)
date_last   = max(dates)

# ── top antipatterns: suggestion categories ────────────────────────────────
kind_counter = Counter()
for kinds in session_kinds.values():
    for k in kinds:
        kind_counter[k] += 1

KIND_LABELS = {
    'skill':   'Skill candidates',
    'prompt':  'Prompt patterns',
    'tool':    'Better tool choices',
    'model':   'Model choice',
    'context': 'Context hygiene',
}

# ── build report ──────────────────────────────────────────────────────────
now_str = datetime.now().isoformat(timespec='seconds')
slug = re.sub(r'[^a-z0-9]+', '-', project_name.lower()).strip('-')

lines = []
lines.append(f"# Project audit — {project_name}")
lines.append("")
lines.append(f"- **Project:** `{project_dir}`")
lines.append(f"- **Generated:** {now_str}")
lines.append(f"- **Sessions analyzed:** {n_sessions}  ({date_first} → {date_last})")
lines.append(f"- **Total cost:** ${total_cost:.2f}  (avg ${avg_cost:.2f}/session)")
lines.append(f"- **Total turns:** {total_turns}")
lines.append("")

# Cost summary table
lines.append("## Cost summary")
lines.append("")
lines.append("| Date | Session | Cost | Turns |")
lines.append("|---|---|---:|---:|")
for e in project_entries:
    lines.append(f"| {e['ts'][:10]} | `{e['sid']}` | ${e['cost']:.2f} | {e['turns']} |")
lines.append("")

# Recurring skill candidates
lines.append("## Recurring skill candidates")
lines.append("")
if recurring_skills:
    lines.append("Files read repeatedly across 2+ sessions — strong candidates for `~/.claude/skills/`:")
    lines.append("")
    lines.append("| File | Sessions | Total reads |")
    lines.append("|---|---:|---:|")
    for fname, nsess, nreads in recurring_skills:
        lines.append(f"| `{fname}` | {nsess} | {nreads} |")
    lines.append("")
    lines.append("**Action:** Create a skill at `~/.claude/skills/<name>.md` that embeds the relevant excerpt, so future sessions load it on-demand instead of re-reading the file.")
    lines.append("")
elif single_skills:
    lines.append("_No files read across 2+ sessions. Single-session candidates (may become recurring):_")
    lines.append("")
    for fname, nsess, nreads in single_skills[:5]:
        lines.append(f"- `{fname}` — read {nreads}× in 1 session")
    lines.append("")
else:
    lines.append("_No repeated file reads detected across sessions._")
    lines.append("")

# Recurring bash patterns
lines.append("## Recurring bash patterns")
lines.append("")
if recurring_bash:
    lines.append("Commands repeated across 2+ sessions — candidates for `.claude/commands/` slash commands:")
    lines.append("")
    lines.append("| Command | Sessions | Total runs |")
    lines.append("|---|---:|---:|")
    for snippet, nsess, nruns in recurring_bash:
        lines.append(f"| `{snippet}` | {nsess} | {nruns} |")
    lines.append("")
    lines.append("**Action:** Create `.claude/commands/<name>.md` with the command and context so `/name` runs it cleanly.")
    lines.append("")
else:
    lines.append("_No bash patterns repeated across 2+ sessions._")
    lines.append("")

# Structural gaps
lines.append("## Structural gaps")
lines.append("")
if gaps:
    for g in gaps:
        lines.append(f"- {g}")
    lines.append("")
else:
    lines.append("_No structural gaps detected — project looks well-configured._")
    lines.append("")

# Top antipatterns
lines.append("## Top suggestion categories")
lines.append("")
if kind_counter:
    lines.append(f"Across {n_sessions} session(s) for this project:")
    lines.append("")
    for kind, cnt in kind_counter.most_common():
        label = KIND_LABELS.get(kind, kind)
        pct = int(100 * cnt / n_sessions)
        lines.append(f"- **{label}** — appeared in {cnt}/{n_sessions} sessions ({pct}%)")
    lines.append("")
else:
    lines.append("_No suggestion categories found (sessions may have been efficient or reports unavailable)._")
    lines.append("")

# Configuration tuning hints (de-duplicated across sessions)
all_config = []
seen_config = set()
for rpath in [e['path'] for e in project_entries]:
    for item in session_config.get(rpath, []):
        key = item[:60]
        if key not in seen_config:
            seen_config.add(key)
            all_config.append(item)

if all_config:
    lines.append("## Configuration tuning (from recent sessions)")
    lines.append("")
    lines.append("_Patterns observed across sessions; these may no longer apply if already actioned:_")
    lines.append("")
    for item in all_config[:5]:
        lines.append(f"- {item}")
    lines.append("")

# Review prompt
audit_path = f"{os.path.expanduser('~/.claude/thermostat')}/project-audit-{slug}.md"
lines.append("## Review with Claude")
lines.append("")
lines.append("```bash")
if do_write:
    lines.append(f'claude "Review my project audit at {audit_path} and help me apply the top suggestion"')
else:
    lines.append(f'./project-audit.sh {project_dir} --write')
    lines.append(f'claude "Review my project audit at {audit_path} and help me apply the top suggestion"')
lines.append("```")
lines.append("")

report_text = '\n'.join(lines)

if do_write:
    os.makedirs(os.path.dirname(audit_path), exist_ok=True)
    with open(audit_path, 'w') as f:
        f.write(report_text)
    # Append to project-audits.log
    log_line = (
        f"{now_str}  {slug}  "
        f"${total_cost:.2f}  {n_sessions}sess  "
        f"{len(recurring_skills)} recurring skill(s)  "
        f"-> {audit_path}\n"
    )
    with open(audit_log, 'a') as f:
        f.write(log_line)
    print(report_text)
    print(f"\n✓ Written to {audit_path}", file=sys.stderr)
    print(f"✓ Logged to {audit_log}", file=sys.stderr)
else:
    print(report_text)
PY

exit 0
