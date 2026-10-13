#!/bin/bash
# RES-132 independent staleness watchdog for the public status.json. Installed on the prod host as
# /usr/local/bin/riq-status-watch, cron: */5 * * * *. The probe itself runs from launchd on the ops Mac;
# if that Mac sleeps or the job dies, status.json stops moving and only this check notices.
# Alerts once per episode when checked_at is older than 15 min (or the file stays unreadable); one recovery message.
# Env overrides (URL, STATE, MAX, RIQ_TEST) are for drills only.
set -u
URL=${RIQ_STATUS_URL:-https://status.resaleiq.dev/status.json}
ST=${RIQ_STATUS_STATE:-/var/lib/riq-status-watch}; mkdir -p "$ST"
MAX=${RIQ_STATUS_MAX_S:-900}
. /usr/local/lib/riq-tg.sh
P=""; [ -n "${RIQ_TEST:-}" ] && P="TEST: "
NOW=$(date -u +%s); PROB=""; AGE=""
J=$(curl -s -m 15 -H 'User-Agent: riq-status-watch/1' "$URL" 2>/dev/null)
TS=$(printf '%s' "$J" | python3 -c 'import sys,json,datetime as d;t=json.load(sys.stdin)["checked_at"];print(int(d.datetime.fromisoformat(t.replace("Z","+00:00")).timestamp()))' 2>/dev/null)
if [ -z "$TS" ]; then
  # a fetch problem is not proof of staleness: need 2 consecutive failures
  F=$(( $(cat "$ST/fetchfail" 2>/dev/null || echo 0) + 1 )); echo "$F" >"$ST/fetchfail"
  [ "$F" -ge 2 ] && PROB="status.json unreadable at $URL ($F checks in a row)"
else
  echo 0 >"$ST/fetchfail"
  AGE=$((NOW - TS))
  [ "$AGE" -gt "$MAX" ] && PROB="status.json checked_at is $((AGE/60)) min old (limit $((MAX/60)) min). The probe on the ops Mac (launchd dev.resaleiq.status-probe) has stopped; the host probe log /var/log/riq-probe.log is still the uptime source."
fi
if [ -n "$PROB" ]; then
  if [ ! -e "$ST/alerted" ]; then
    if tg_send "${P}🟠 Resale IQ STATUS PAGE STALE: $PROB"; then touch "$ST/alerted"; echo "$(date -u +%FT%TZ) alert sent: $PROB"
    else echo "$(date -u +%FT%TZ) alert SEND FAILED: $PROB"; fi
  else echo "$(date -u +%FT%TZ) stale, already alerted"; fi
else
  if [ -e "$ST/alerted" ]; then tg_send "${P}✅ Resale IQ status page is updating again." && rm "$ST/alerted"; fi
  echo "$(date -u +%FT%TZ) ok age=${AGE:-?}s"
fi
