---
name: jarvis-rich-responses
description: "Use when replying in the JARVIS iPhone app and a poll, chart, table, form, buttons, checklist or card would help."
---

# Rich responses in the JARVIS iPhone app

The JARVIS iPhone app (v3, source `hermex`) renders `jarvis-rich` blocks natively. Other
surfaces (WhatsApp, Signal, Discord, the dashboard) show them as raw JSON, so use them only in
app sessions. The app's own platform note already tells you the format; this skill is the
fuller reference.

## When

Use a block when it beats prose: a decision between options (poll or buttons), numbers over
time or a breakdown (chart, always with real data), a comparison (table), a few inputs you
need from Enrique (form), steps to tick off (checklist), a summary card, a warning (notice),
or sources (citation). Keep ordinary prose outside the block. One or two blocks per reply.

## Format

One fenced block, language tag `jarvis-rich`, holding a JSON object with `blocks`:

````
```jarvis-rich
{"blocks": [
  {"id": "q1", "type": "poll", "props": {"question": "Which deploy window?", "options": ["Tonight 10pm", "Tomorrow 7am"]},
   "fallbackText": "Poll: deploy tonight 10pm or tomorrow 7am"},
  {"id": "c1", "type": "chart", "props": {"kind": "bar", "title": "Orders this week",
   "points": [{"label": "Mon", "value": 12}, {"label": "Tue", "value": 18}]},
   "fallbackText": "Orders: Mon 12, Tue 18"}
]}
```
````

Every block: `id` (unique in the reply), `type`, `props`, `fallbackText` (a plain summary,
shown if the block can't render and used in PDF export). Optional: `version` ("1.0.0"),
`a11yLabel`, `actions`.

| type | props |
|---|---|
| text | `text` |
| markdown | `markdown` |
| heading | `text`, `level` (1-3) |
| code | `code`, `language` |
| table | `headers: [String]`, `rows: [[String]]` |
| chart | `kind: bar\|line\|pie`, `title`, `points: [{label, value}]` (the app also shows the data table) |
| poll | `question`, `options: [String]` |
| buttonGroup | `buttons: [{id, label, kind}]`; `kind`: `submit` (sends the label back), `openUrl` (+ `url`, https only), `copy` |
| form | `fields: [{id, kind: text\|number\|date\|select\|checkbox, label, required, options}]`, `submitLabel` |
| checklist | `items: [{id, text, isChecked}]` |
| card | `title`, `subtitle`, `body` (markdown) |
| notice | `tone: info\|success\|warning\|error`, `text` |
| citation | `title`, `url` (https) |
| image | `url` (https), `alt`, `caption` |

## What comes back

A tapped `submit` button, a poll vote or a submitted form arrives as Enrique's next message
(the button label; "Vote: <option>" with the question on the next line; or the submit label followed by one "Label: value" line per answered field). Treat it like any
reply from him.

## Rules

- Real data only. Never invent numbers for a chart or results for a poll.
- Never put secrets, tokens or passwords in a block.
- Links and images: https only.
- If unsure the app is the surface, write plain markdown instead.
