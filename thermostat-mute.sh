#!/usr/bin/env bash
# thermostat-mute: per-session mute for claude-thermostat.
#
#   thermostat-mute.sh                    mute the most recently modified session
#   thermostat-mute.sh <session_id>       mute that session
#   thermostat-mute.sh --unmute [id]      unmute (default: most recent session)
#   thermostat-mute.sh --off [id]         alias for --unmute
#   thermostat-mute.sh --status           list muted sessions
#
# Mute = marker file ~/.claude/thermostat/<session_id>.muted, checked by
# claude-thermostat.sh before any analysis. Written atomically (tmp + mv).

set -u

STATE_DIR="$HOME/.claude/thermostat"
ID_RE='^[0-9A-Za-z_-]+$'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$'

die() { echo "thermostat-mute: $*" >&2; exit 1; }

# Most recently modified session state file -> session id.
latest_session() {
  local f base
  # shellcheck disable=SC2012
  for f in $(ls -t "$STATE_DIR"/*.json 2>/dev/null); do
    base="$(basename "$f")"
    if [[ "$base" =~ $UUID_RE ]]; then echo "${base%.json}"; return 0; fi
  done
  return 1
}

action=mute
sid=""
for arg in "$@"; do
  case "$arg" in
    --unmute|--off) action=unmute ;;
    --status) action=status ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) [ -z "$sid" ] || die "only one session id allowed"; sid="$arg" ;;
  esac
done

if [ "$action" = status ]; then
  found=0
  for f in "$STATE_DIR"/*.muted; do
    [ -e "$f" ] || continue
    echo "muted: $(basename "${f%.muted}")"
    found=1
  done
  [ "$found" = 1 ] || echo "no muted sessions"
  exit 0
fi

if [ -z "$sid" ]; then
  sid="$(latest_session)" || die "no session state files in $STATE_DIR; pass a session id"
fi
[[ "$sid" =~ $ID_RE ]] || die "invalid session id: $sid"

marker="$STATE_DIR/$sid.muted"
if [ "$action" = mute ]; then
  mkdir -p "$STATE_DIR"
  tmp="$marker.tmp.$$"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp" && mv "$tmp" "$marker" || { rm -f "$tmp"; die "could not write $marker"; }
  echo "muted session $sid (created $marker)"
else
  if [ -f "$marker" ]; then rm -f "$marker"; echo "unmuted session $sid (removed $marker)"
  else echo "session $sid was not muted (nothing changed)"; fi
fi
