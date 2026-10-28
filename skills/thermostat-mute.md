---
name: thermostat-mute
description: Mute the cost/context nags from claude-thermostat for the current session only (or unmute / check status).
triggers:
  - /thermostat-mute
  - mute the thermostat
  - stop the thermostat nags
---

Run `thermostat-mute.sh` using the Bash tool (add `--unmute` or `--status` if the user asked for that) and report its output verbatim. Resolve the script as `$THERMOSTAT_DIR/thermostat-mute.sh`, else on PATH, else `find "$HOME" -maxdepth 6 -name thermostat-mute.sh -type f | head -1`.
