#!/usr/bin/env bash
# Seeds JARVIS documents for Maestro flow 12 and keeps them changing, the way JARVIS's cron jobs
# would: data/qa-live.json gets new numbers every 2 s (the dashboard's Jarvis.live), and
# "Meeting Notes.html" a new revision every 6 s (the app reloads a changed document in place).
# Usage: feed.sh <documents folder> <seconds to run>
set -euo pipefail
FIXTURES="$(cd "$(dirname "$0")" && pwd)"
DOCS="$1"
RUN_FOR="${2:-600}"
mkdir -p "$DOCS/data"
cp "$FIXTURES/📈 Live Dashboard.html" "$DOCS/"

write_notes() {
  sed "s/REVISION/$1/" "$FIXTURES/Meeting Notes.html" > "$DOCS/.notes.tmp"
  mv "$DOCS/.notes.tmp" "$DOCS/Meeting Notes.html"
}

write_data() {
  local i=$1
  cat > "$DOCS/data/.live.tmp" <<JSON
{"tick": $i, "revenue": $((12400 + i * 37)), "growth": 0.$((10 + i % 9)), "orders": $((140 + i)),
 "conversion": 0.0$((31 + i % 7)),
 "trend": [{"label": "Mon", "value": 1620, "previous": 1410}, {"label": "Tue", "value": 1810, "previous": 1580},
           {"label": "Wed", "value": 1540, "previous": 1490}, {"label": "Thu", "value": 2100, "previous": 1720},
           {"label": "Fri", "value": 2380, "previous": 2010}, {"label": "Sat", "value": $((2600 + (i % 5) * 90)), "previous": 2240},
           {"label": "Sun", "value": $((1900 + (i % 7) * 60)), "previous": 1830}],
 "channels": [{"label": "Instagram", "value": $((5200 + i * 9))}, {"label": "TikTok", "value": 3100},
              {"label": "Email", "value": 1900}, {"label": "Direct", "value": 1200}],
 "products": [{"name": "Linen tote", "sold": $((41 + i % 4)), "status": "In stock"},
              {"name": "Ceramic mug", "sold": 33, "status": "Low"},
              {"name": "Candle set", "sold": 27, "status": "Reordered"}]}
JSON
  mv "$DOCS/data/.live.tmp" "$DOCS/data/qa-live.json"
}

i=1
write_notes 1
write_data 1
end=$((SECONDS + RUN_FOR))
while [ "$SECONDS" -lt "$end" ]; do
  sleep 2
  i=$((i + 1))
  write_data "$i"
  if [ $((i % 3)) -eq 0 ]; then write_notes $((i / 3 + 1)); fi
done
