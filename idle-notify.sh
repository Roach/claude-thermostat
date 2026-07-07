#!/usr/bin/env bash
# idle-notify: desktop notification when Claude Code is blocked waiting on you.
#
# An open session that sits idle burns money quietly: every gap past the
# 5-minute cache TTL means the next turn re-writes the full context at 1.25x
# input instead of reading it at 0.1x (the cooldown report's "cache
# expirations" signal), and sessions left open for hours drift into the
# multi-day staleness pattern. The cheapest fix is simply knowing the agent
# is waiting — answer it or close it.
#
# Wire-up (~/.claude/settings.json):
#   "Notification": [{ "hooks": [{ "type": "command",
#                    "command": "/abs/path/to/claude-thermostat/idle-notify.sh" }] }]
#
# Always exits 0 — a notification failure must never block the session.

set -u

input="$(cat)"

msg="$(printf '%s' "$input" | /usr/bin/python3 -c \
  "import json,sys; d=json.load(sys.stdin); print((d.get('message') or 'Claude Code needs your attention')[:200])" \
  2>/dev/null || echo 'Claude Code needs your attention')"

case "$(uname -s)" in
  Darwin)
    /usr/bin/osascript -e "display notification \"${msg//\"/\\\"}\" with title \"Claude Code\" sound name \"Glass\"" >/dev/null 2>&1
    ;;
  Linux)
    command -v notify-send >/dev/null 2>&1 && notify-send "Claude Code" "$msg" >/dev/null 2>&1
    ;;
esac

exit 0
