---
name: jarvis-widgets
description: "Use when Enrique asks for an iPhone home-screen widget in the JARVIS app: design it as a jarvis-widget block and, for live numbers, keep its data file current."
---

# Home-screen widgets for the JARVIS iPhone app

The JARVIS iPhone app (v3, source `hermex`) turns a ```` ```jarvis-widget ```` block in your
reply into a widget preview with **Add to Home Screen**. Other surfaces show it as raw JSON, so
use it only in app sessions.

## The block

````
```jarvis-widget
{"id": "zai-usage", "title": "Z.AI usage", "subtitle": "Both Lite plans", "symbol": "gauge.with.dots.needle.67percent",
 "accent": "#3FD6F5", "style": "list",
 "rows": [{"label": "Plan A 5h", "value": "41%"}, {"label": "Plan B 5h", "value": "12%"}],
 "data": "~/JARVIS-Files/widgets/zai-usage.json"}
```
````

| field | notes |
|---|---|
| `id` | required, short and stable; sending the same id again updates the widget |
| `title` | required, short (one line on a small widget) |
| `subtitle` | optional, shown on medium and large |
| `symbol` | optional SF Symbol name |
| `accent` | optional `#RRGGBB`; default Jarvis Cyan |
| `style` | `metric` (one big `value` + `caption` + `trend`), `list` (`rows`, up to 3/4/8 by size), `chart` (bar `points`, optional `value` headline) |
| `value`, `caption`, `trend` | text; a `trend` starting with `-` shows red, otherwise green |
| `rows` | `[{"label", "value"}]` |
| `points` | `[{"label", "value": number}]` |
| `data` | optional live data file, must be inside `~/JARVIS-Files` |

## Live data

For numbers that change, write `~/JARVIS-Files/widgets/<id>.json` with any of `value`,
`caption`, `trend`, `title`, `rows`, `points`, plus `updated` (ISO 8601), and keep it current
with a cron job at a sensible interval. The app reads it each time it opens and redraws the
widget. Create `~/JARVIS-Files/widgets/` if it is missing.

## Rules

- Real data only. If you can't get the numbers, say so instead of inventing them.
- No secrets, tokens or personal data beyond what Enrique asked to see.
- One widget per block; keep titles short.
- After the block, tell him in one line how to place it: touch and hold the home screen,
  Edit, Add Widget, JARVIS.
