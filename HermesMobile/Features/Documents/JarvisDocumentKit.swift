import WebKit

/// The look and helpers every document gets (`JarvisDocumentWebView`): a Notion-like stylesheet
/// for plain HTML in light and dark mode, plus classes for callouts, cards, KPIs, tags, progress
/// bars, boards and columns, and `window.Jarvis`: `live` re-renders from a JSON file JARVIS keeps
/// current, `chart` draws line, area, bar, pie and donut charts as SVG, and `json`, `text`, `h`,
/// `table` and `format` help build a page. The base element styles have no specificity
/// (`:where`), so a document's own CSS always wins, and `<meta name="jarvis-kit" content="off">`
/// drops the stylesheet. The platform note (`HermesREST.platformNote`) is how JARVIS learns these
/// names: keep the two in step.
enum JarvisDocumentKit {
    @MainActor static func userScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// The stylesheet goes in first, ahead of the document's own, then the viewport (a document's
    /// own viewport tag, parsed later, replaces it), then the helpers.
    static let source: String = {
        let css = (try? JSONEncoder().encode(style)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
            (function () {
              var root = document.documentElement;
              var style = document.createElement("style");
              style.id = "jarvis-kit";
              style.textContent = \(css);
              root.appendChild(style);
              var viewport = document.createElement("meta");
              viewport.name = "viewport";
              viewport.content = "width=device-width, initial-scale=1";
              root.appendChild(viewport);
            })();

            """ + script
    }()

    static let style = #"""
        :root {
          color-scheme: light dark;
          --jd-bg: #ffffff; --jd-surface: #f7f7f5; --jd-text: #37352f; --jd-muted: #787774;
          --jd-faint: rgba(55, 53, 47, 0.07); --jd-border: rgba(55, 53, 47, 0.14);
          --jd-accent: #0a8fb5; --jd-code: #d44c47; --jd-radius: 8px;
          --jd-gray: #787774; --jd-gray-bg: #f1f1ef; --jd-brown: #9f6b53; --jd-brown-bg: #f4eeee;
          --jd-orange: #d9730d; --jd-orange-bg: #fbecdd; --jd-yellow: #b58a1e; --jd-yellow-bg: #fbf3db;
          --jd-green: #448361; --jd-green-bg: #edf3ec; --jd-blue: #337ea9; --jd-blue-bg: #e7f3f8;
          --jd-purple: #9065b0; --jd-purple-bg: #f6f3f9; --jd-pink: #c14c8a; --jd-pink-bg: #faf1f5;
          --jd-red: #d44c47; --jd-red-bg: #fdebec;
          --jd-chart-1: #1f9bc4; --jd-chart-2: #e8743b; --jd-chart-3: #19a979; --jd-chart-4: #945ecf;
          --jd-chart-5: #e5487a; --jd-chart-6: #d9a21b; --jd-chart-7: #5c87d6; --jd-chart-8: #13a4a4;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --jd-bg: #070e14; --jd-surface: #0c1b24; --jd-text: #e6eef2; --jd-muted: #8ea2ad;
            --jd-faint: rgba(230, 255, 255, 0.06); --jd-border: rgba(230, 255, 255, 0.12);
            --jd-accent: #3fd6f5; --jd-code: #ff7369;
            --jd-gray: #9b9b9b; --jd-gray-bg: #252b30; --jd-brown: #ba856f; --jd-brown-bg: #3a2a22;
            --jd-orange: #e08a4c; --jd-orange-bg: #47301d; --jd-yellow: #d6aa55; --jd-yellow-bg: #433824;
            --jd-green: #5bb381; --jd-green-bg: #1d3528; --jd-blue: #4fb0e6; --jd-blue-bg: #11344a;
            --jd-purple: #ad80df; --jd-purple-bg: #31263f; --jd-pink: #df6aa5; --jd-pink-bg: #432636;
            --jd-red: #ec6764; --jd-red-bg: #482524;
            --jd-chart-1: #3fd6f5; --jd-chart-2: #ff9a5a; --jd-chart-3: #3ccf91; --jd-chart-4: #b28bf0;
            --jd-chart-5: #ff6f9b; --jd-chart-6: #ffcb57; --jd-chart-7: #7cb5ff; --jd-chart-8: #36d1c4;
          }
        }
        :where(html) { background: var(--jd-bg); color: var(--jd-text); -webkit-text-size-adjust: 100%; }
        :where(body) {
          margin: 0 auto; max-width: 780px; padding: 20px 18px 48px;
          font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; line-height: 1.55;
          overflow-wrap: break-word;
        }
        :where(h1, h2, h3, h4) { font-weight: 700; line-height: 1.25; letter-spacing: -0.01em; margin: 1.5em 0 0.35em; }
        :where(h1) { font-size: 1.85em; margin-top: 0.5em; }
        :where(h2) { font-size: 1.4em; }
        :where(h3) { font-size: 1.17em; }
        :where(h4) { font-size: 1em; }
        :where(p) { margin: 0.3em 0 0.75em; }
        :where(a) { color: inherit; text-decoration: underline; text-decoration-color: var(--jd-border); text-underline-offset: 2px; }
        :where(ul, ol) { padding-left: 1.5em; margin: 0.3em 0 0.85em; }
        :where(li) { margin: 0.2em 0; }
        :where(blockquote) { margin: 0.8em 0; padding: 0.05em 0 0.05em 0.95em; border-left: 3px solid currentColor; }
        :where(hr) { border: 0; border-top: 1px solid var(--jd-border); margin: 1.4em 0; }
        :where(code) {
          font: 0.86em ui-monospace, "SF Mono", Menlo, monospace; color: var(--jd-code);
          background: var(--jd-faint); padding: 0.12em 0.35em; border-radius: 4px;
        }
        :where(pre) {
          background: var(--jd-surface); border: 1px solid var(--jd-border); border-radius: var(--jd-radius);
          padding: 12px 14px; overflow-x: auto; font-size: 0.85em; line-height: 1.45;
        }
        :where(pre code) { color: inherit; background: none; padding: 0; font-size: 1em; }
        :where(img, video, canvas, svg, iframe) { max-width: 100%; }
        :where(img) { height: auto; border-radius: 6px; }
        :where(iframe) { border: 0; border-radius: var(--jd-radius); }
        :where(table) {
          border-collapse: separate; border-spacing: 0; width: 100%; font-size: 0.92em;
          border-top: 1px solid var(--jd-border); border-left: 1px solid var(--jd-border);
        }
        :where(th, td) {
          border-right: 1px solid var(--jd-border); border-bottom: 1px solid var(--jd-border);
          padding: 7px 10px; text-align: left; vertical-align: top;
        }
        :where(th) { color: var(--jd-muted); font-weight: 500; }
        :where(td.num, th.num) { text-align: right; font-variant-numeric: tabular-nums; }
        :where(details) { margin: 0.25em 0; }
        :where(details) > :where(:not(summary)) { margin-left: 1.4em; }
        :where(summary) { cursor: pointer; list-style: none; position: relative; padding: 2px 0 2px 1.4em; font-weight: 500; }
        :where(summary)::-webkit-details-marker { display: none; }
        :where(summary)::before { content: "\25B8"; position: absolute; left: 0.25em; color: var(--jd-muted); transition: transform 0.15s; }
        :where(details[open] > summary)::before { transform: rotate(90deg); }
        :where(input[type="checkbox"]) { accent-color: var(--jd-accent); width: 1.05em; height: 1.05em; vertical-align: -0.12em; }
        :where(button) {
          font: inherit; color: inherit; background: var(--jd-faint); border: 1px solid var(--jd-border);
          border-radius: 6px; padding: 6px 12px;
        }
        :where(mark) { background: var(--jd-yellow-bg); color: inherit; padding: 0 2px; border-radius: 3px; }

        .page-icon { font-size: 3em; line-height: 1; margin: 0.2em 0 0.15em; }
        .cover { height: 132px; margin: -20px -18px 14px; background: linear-gradient(135deg, #0c1b24, #3fd6f5) center / cover; }
        .muted, .subtitle { color: var(--jd-muted); }
        .small { font-size: 0.85em; }
        .callout {
          display: flex; gap: 10px; align-items: flex-start; margin: 0.8em 0; padding: 12px 14px;
          border-radius: var(--jd-radius); background: var(--jd-gray-bg);
        }
        .callout > .icon { font-size: 1.15em; line-height: 1.35; }
        .callout > :not(.icon) { flex: 1; min-width: 0; }
        .callout p { margin: 0.15em 0; }
        .callout.info { background: var(--jd-blue-bg); }
        .callout.success { background: var(--jd-green-bg); }
        .callout.warning { background: var(--jd-yellow-bg); }
        .callout.danger { background: var(--jd-red-bg); }
        .columns, .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 220px), 1fr)); gap: 14px; margin: 0.8em 0; }
        .card {
          background: var(--jd-surface); border: 1px solid var(--jd-border); border-radius: 10px;
          padding: 12px 14px; margin: 0.6em 0;
        }
        .columns > .card, .grid > .card, .kpis > .kpi { margin: 0; }
        .card > :first-child { margin-top: 0; }
        .card > :last-child { margin-bottom: 0; }
        .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 140px), 1fr)); gap: 10px; margin: 0.8em 0; }
        .kpi { background: var(--jd-surface); border: 1px solid var(--jd-border); border-radius: 10px; padding: 11px 13px; }
        .kpi .label { font-size: 0.75em; color: var(--jd-muted); text-transform: uppercase; letter-spacing: 0.04em; }
        .kpi .value { font-size: 1.55em; font-weight: 700; line-height: 1.2; margin-top: 2px; font-variant-numeric: tabular-nums; }
        .kpi .delta { font-size: 0.8em; font-weight: 600; }
        .up { color: var(--jd-green); }
        .down { color: var(--jd-red); }
        .tag {
          display: inline-block; padding: 0 7px; border-radius: 4px; font-size: 0.8em; line-height: 1.65;
          white-space: nowrap; background: var(--jd-gray-bg); color: var(--jd-text);
        }
        .tag.gray { color: var(--jd-gray); } .tag.brown { background: var(--jd-brown-bg); color: var(--jd-brown); }
        .tag.orange { background: var(--jd-orange-bg); color: var(--jd-orange); }
        .tag.yellow { background: var(--jd-yellow-bg); color: var(--jd-yellow); }
        .tag.green { background: var(--jd-green-bg); color: var(--jd-green); }
        .tag.blue { background: var(--jd-blue-bg); color: var(--jd-blue); }
        .tag.purple { background: var(--jd-purple-bg); color: var(--jd-purple); }
        .tag.pink { background: var(--jd-pink-bg); color: var(--jd-pink); }
        .tag.red { background: var(--jd-red-bg); color: var(--jd-red); }
        .progress { height: 6px; border-radius: 3px; background: var(--jd-faint); overflow: hidden; margin: 6px 0; }
        .progress > span { display: block; height: 100%; border-radius: inherit; background: var(--jd-accent); }
        .board { display: flex; gap: 12px; overflow-x: auto; margin: 0.8em 0; padding-bottom: 4px; scroll-snap-type: x proximity; }
        .board > .column { flex: 0 0 min(78%, 260px); scroll-snap-align: start; }
        .board > .column > h4, .board > .column > .title { font-size: 0.85em; color: var(--jd-muted); margin: 0 0 8px; }
        .board .card { margin: 0 0 8px; padding: 10px 12px; }
        .todo { list-style: none; padding-left: 0.1em; }
        .todo li { display: flex; gap: 8px; align-items: baseline; }
        .todo li.done { color: var(--jd-muted); text-decoration: line-through; }
        .updated { font-size: 0.8em; color: var(--jd-muted); }
        .jd-scroll { overflow-x: auto; margin: 0.8em 0; }
        .jd-scroll > table { margin: 0; }
        .chart { margin: 0.8em 0; }
        .jd-chart { display: block; overflow: visible; }
        .jd-chart text { fill: var(--jd-muted); font: 11px -apple-system, system-ui, sans-serif; }
        .jd-chart .grid { stroke: var(--jd-border); stroke-width: 1; }
        .jd-chart-title { font-weight: 600; margin: 0 0 6px; }
        .jd-pie { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; }
        .jd-legend { list-style: none; padding: 0; margin: 6px 0 0; display: flex; flex-wrap: wrap; gap: 4px 14px; font-size: 0.85em; }
        .jd-legend li { margin: 0; }
        .jd-legend .sw { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 6px; vertical-align: -1px; }
        @media (prefers-reduced-motion: reduce) {
          *, ::before, ::after { transition: none !important; animation: none !important; scroll-behavior: auto !important; }
        }
        """#

    static let script = #"""
        (function () {
          "use strict";
          if (window.Jarvis) return;

          function esc(value) {
            return String(value == null ? "" : value).replace(/[&<>"']/g, function (c) {
              return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c];
            });
          }

          function xhr(path) {
            return new Promise(function (resolve, reject) {
              var request = new XMLHttpRequest();
              request.open("GET", path);
              request.onload = function () {
                if (request.status >= 200 && request.status < 300) resolve(request.responseText);
                else reject(new Error(path + " answered " + request.status));
              };
              request.onerror = function () { reject(new Error(path + " could not be read")); };
              request.send();
            });
          }

          // A file JARVIS keeps, by a path relative to the document (or an https URL).
          function text(path) {
            return fetch(path, { cache: "no-store" }).then(function (response) {
              if (!response.ok) throw new Error(path + " answered " + response.status);
              return response.text();
            }, function () { return xhr(path); });
          }

          function json(path) { return text(path).then(JSON.parse); }

          // Calls render(data) with the file's JSON now and whenever it changes, checking every
          // `seconds` (at least 2) while the page is on screen. Returns { stop, refresh }.
          function live(path, render, seconds) {
            var every = Math.max(2, Number(seconds) || 5) * 1000, last, timer, busy = false, stopped = false;
            function tick() {
              clearTimeout(timer);
              if (stopped || busy) return;
              if (document.hidden) { timer = setTimeout(tick, every); return; }
              busy = true;
              text(path).then(function (body) {
                if (body === last) return;
                last = body;
                var data;
                try { data = JSON.parse(body); } catch (e) { data = body; }
                try { render(data); } catch (e) { console.error("Jarvis.live render", e); }
              }).catch(function (e) { console.warn("Jarvis.live", e); }).then(function () {
                busy = false;
                if (!stopped) timer = setTimeout(tick, every);
              });
            }
            document.addEventListener("visibilitychange", function () { if (!document.hidden) tick(); });
            tick();
            return { stop: function () { stopped = true; clearTimeout(timer); }, refresh: tick };
          }

          var format = {
            number: function (v, digits) {
              return new Intl.NumberFormat(undefined, { maximumFractionDigits: digits == null ? 2 : digits }).format(v);
            },
            compact: function (v) {
              return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(v);
            },
            currency: function (v, code, compact) {
              var options = { style: "currency", currency: code || "USD" };
              if (compact) { options.notation = "compact"; options.maximumFractionDigits = 1; }
              return new Intl.NumberFormat(undefined, options).format(v);
            },
            percent: function (v, digits) {
              return new Intl.NumberFormat(undefined, { style: "percent", maximumFractionDigits: digits == null ? 1 : digits }).format(v);
            },
            timeAgo: function (date) {
              var then = date instanceof Date ? date : new Date(date);
              var seconds = Math.round((then.getTime() - Date.now()) / 1000);
              var rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
              var units = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]];
              for (var i = 0; i < units.length; i++) {
                if (Math.abs(seconds) >= units[i][1]) return rtf.format(Math.round(seconds / units[i][1]), units[i][0]);
              }
              return rtf.format(Math.abs(seconds) < 10 ? 0 : seconds, "second");
            }
          };

          // h("div", { class: "card", onclick: fn }, "text", child, [more]) builds an element.
          function h(tag, attrs) {
            var el = document.createElement(tag);
            Object.keys(attrs || {}).forEach(function (key) {
              var value = attrs[key];
              if (value == null || value === false) return;
              if (key === "class") el.className = value;
              else if (key === "style" && typeof value === "object") Object.assign(el.style, value);
              else if (key.slice(0, 2) === "on" && typeof value === "function") el.addEventListener(key.slice(2), value);
              else if (key === "html") el.innerHTML = value;
              else el.setAttribute(key, value === true ? "" : value);
            });
            (function add(children) {
              children.forEach(function (child) {
                if (child == null || child === false) return;
                if (Array.isArray(child)) add(child);
                else el.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
              });
            })(Array.prototype.slice.call(arguments, 2));
            return el;
          }

          function element(target) { return typeof target === "string" ? document.querySelector(target) : target; }

          // table(target, { columns: ["Name", "Value"], rows: [["a", 1]] }) fills target with a table.
          function table(target, spec) {
            var el = element(target);
            if (!el) return;
            var head = h("tr", null, (spec.columns || []).map(function (c) { return h("th", null, c); }));
            var body = (spec.rows || []).map(function (row) {
              return h("tr", null, row.map(function (cell) { return h("td", typeof cell === "number" ? { class: "num" } : null, cell); }));
            });
            el.replaceChildren(h("div", { class: "jd-scroll" }, h("table", null, h("thead", null, head), h("tbody", null, body))));
          }

          function color(i, own) { return own ? esc(own) : "var(--jd-chart-" + ((i % 8) + 1) + ")"; }

          function seriesOf(spec) {
            var list = spec.series || [{ name: spec.name || "", color: spec.color, points: spec.points || [] }];
            return list.map(function (s) {
              return {
                name: s.name || "", color: s.color,
                points: (s.points || []).map(function (p) {
                  return { label: p.label == null ? "" : String(p.label), value: Number(p.value) || 0, color: p.color };
                })
              };
            });
          }

          function formatters(kind) {
            if (typeof kind === "function") return [kind, kind];
            if (kind === "percent") return [function (v) { return format.percent(v); }, function (v) { return format.percent(v, 0); }];
            var code = kind === "currency" ? "USD" : (/^[A-Z]{3}$/.test(kind || "") ? kind : null);
            if (code) return [function (v) { return format.currency(v, code); }, function (v) { return format.currency(v, code, true); }];
            return [function (v) { return format.number(v); }, format.compact];
          }

          function niceStep(x) {
            var e = Math.pow(10, Math.floor(Math.log10(x))), f = x / e;
            return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * e;
          }

          function ticks(lo, hi) {
            if (lo === hi) { if (lo === 0) hi = 1; else { var pad = Math.abs(lo) * 0.1; lo -= pad; hi += pad; } }
            var step = niceStep((hi - lo) / 3), out = [];
            for (var v = Math.floor(lo / step) * step; v <= Math.ceil(hi / step) * step + step / 2; v += step) out.push(Math.round(v / step) * step);
            return out;
          }

          function slice(cx, cy, r, inner, a0, a1, fill) {
            if (a1 - a0 >= Math.PI * 2 - 1e-6) {
              return inner
                ? '<circle cx="' + cx + '" cy="' + cy + '" r="' + ((r + inner) / 2) + '" style="fill:none;stroke:' + fill + ";stroke-width:" + (r - inner) + '"/>'
                : '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '" style="fill:' + fill + '"/>';
            }
            function at(radius, a) { return (cx + radius * Math.cos(a)).toFixed(2) + " " + (cy + radius * Math.sin(a)).toFixed(2); }
            var large = a1 - a0 > Math.PI ? 1 : 0;
            var d = "M" + at(r, a0) + " A" + r + " " + r + " 0 " + large + " 1 " + at(r, a1);
            d += inner ? " L" + at(inner, a1) + " A" + inner + " " + inner + " 0 " + large + " 0 " + at(inner, a0) + " Z" : " L" + cx + " " + cy + " Z";
            return '<path d="' + d + '" style="fill:' + fill + '"/>';
          }

          function pie(spec, width, donut, full) {
            var points = seriesOf(spec)[0].points.filter(function (p) { return p.value > 0; });
            var total = points.reduce(function (sum, p) { return sum + p.value; }, 0);
            if (!total) return '<div class="muted small">No data</div>';
            var size = Math.min(width, spec.height || 200), r = size / 2 - 2, inner = donut ? r * 0.62 : 0, a = -Math.PI / 2;
            var svg = '<svg class="jd-chart" viewBox="0 0 ' + size + " " + size + '" width="' + size + '" height="' + size +
              '" role="img" aria-label="' + esc(spec.title || "Pie chart") + '">';
            var legend = "";
            points.forEach(function (p, i) {
              var share = p.value / total, fill = color(i, p.color);
              svg += slice(size / 2, size / 2, r, inner, a, a + share * Math.PI * 2, fill);
              a += share * Math.PI * 2;
              legend += '<li><span class="sw" style="background:' + fill + '"></span>' + esc(p.label) +
                ' <span class="muted">' + esc(full(p.value)) + " · " + Math.round(share * 100) + "%</span></li>";
            });
            if (donut) svg += '<text x="50%" y="50%" dy="0.35em" text-anchor="middle" style="font-size:15px;font-weight:700;fill:var(--jd-text)">' + esc(full(total)) + "</text>";
            return '<div class="jd-pie">' + svg + '</svg><ul class="jd-legend">' + legend + "</ul></div>";
          }

          function plot(spec, width) {
            var kind = String(spec.kind || "line").toLowerCase(), pair = formatters(spec.format), full = pair[0], axis = pair[1];
            var title = spec.title ? '<div class="jd-chart-title">' + esc(spec.title) + "</div>" : "";
            if (kind === "pie" || kind === "donut") return title + pie(spec, width, kind === "donut", full);
            var series = seriesOf(spec), n = 0, labels = [], values = [];
            series.forEach(function (s) {
              if (s.points.length > n) { n = s.points.length; labels = s.points.map(function (p) { return p.label; }); }
              s.points.forEach(function (p) { values.push(p.value); });
            });
            if (!n) return title + '<div class="muted small">No data</div>';
            var W = Math.max(220, Math.round(width)), H = spec.height || Math.round(Math.min(280, Math.max(170, W * 0.55)));
            var lo = Math.min.apply(null, values), hi = Math.max.apply(null, values);
            if (kind !== "line" || spec.zero === true) { lo = Math.min(0, lo); hi = Math.max(0, hi); }
            var ys = ticks(lo, hi);
            lo = ys[0]; hi = ys[ys.length - 1];
            var yText = ys.map(axis), widest = yText.reduce(function (m, t) { return Math.max(m, String(t).length); }, 1);
            var left = Math.min(72, 12 + widest * 6.4), right = 8, top = series.length > 1 ? 28 : 10, bottom = 24;
            var pw = W - left - right, ph = H - top - bottom, band = pw / n;
            function y(v) { return top + ph - (v - lo) / (hi - lo || 1) * ph; }
            function x(i) { return kind === "bar" ? left + band * (i + 0.5) : left + (n === 1 ? pw / 2 : pw * i / (n - 1)); }
            var out = ['<svg class="jd-chart" viewBox="0 0 ' + W + " " + H + '" width="100%" height="' + H +
              '" preserveAspectRatio="none" role="img" aria-label="' + esc(spec.title || kind + " chart") + '">'];
            ys.forEach(function (v, i) {
              var yy = y(v).toFixed(1);
              out.push('<line class="grid" x1="' + left + '" x2="' + (W - right) + '" y1="' + yy + '" y2="' + yy + '"/>');
              out.push('<text x="' + (left - 6) + '" y="' + yy + '" dy="0.32em" text-anchor="end">' + esc(yText[i]) + "</text>");
            });
            var longest = labels.reduce(function (m, l) { return Math.max(m, l.length); }, 1);
            var every = Math.max(1, Math.ceil(n * Math.max(28, longest * 6.4 + 12) / pw));
            for (var i = 0; i < n; i += every) {
              var anchor = kind === "bar" || n === 1 ? "middle" : i === 0 ? "start" : (i + every >= n && i === n - 1 ? "end" : "middle");
              out.push('<text x="' + x(i).toFixed(1) + '" y="' + (H - 6) + '" text-anchor="' + anchor + '">' + esc(labels[i]) + "</text>");
            }
            var base = y(Math.max(lo, Math.min(0, hi)));
            series.forEach(function (s, si) {
              var c = color(si, s.color);
              if (kind === "bar") {
                var group = band * 0.72, bw = group / series.length;
                s.points.forEach(function (p, i) {
                  var bx = left + band * i + (band - group) / 2 + bw * si, by = y(p.value);
                  var fill = series.length === 1 && p.color ? esc(p.color) : c;
                  out.push('<rect x="' + (bx + 1).toFixed(1) + '" y="' + Math.min(by, base).toFixed(1) + '" width="' + Math.max(1, bw - 2).toFixed(1) +
                    '" height="' + Math.max(1, Math.abs(base - by)).toFixed(1) + '" rx="3" style="fill:' + fill + '"><title>' +
                    esc(p.label + ": " + full(p.value)) + "</title></rect>");
                });
                return;
              }
              var d = s.points.map(function (p, i) { return (i ? "L" : "M") + x(i).toFixed(1) + " " + y(p.value).toFixed(1); }).join(" ");
              if (kind === "area" && s.points.length > 1) {
                out.push('<path d="' + d + " L" + x(s.points.length - 1).toFixed(1) + " " + base.toFixed(1) + " L" + x(0).toFixed(1) + " " + base.toFixed(1) +
                  ' Z" style="fill:' + c + ';fill-opacity:0.16;stroke:none"/>');
              }
              out.push('<path d="' + d + '" style="fill:none;stroke:' + c + ';stroke-width:2.25;stroke-linejoin:round;stroke-linecap:round" vector-effect="non-scaling-stroke"/>');
              var last = s.points[s.points.length - 1];
              if (last) out.push('<circle cx="' + x(s.points.length - 1).toFixed(1) + '" cy="' + y(last.value).toFixed(1) + '" r="3.5" style="fill:' + c + '"/>');
            });
            if (series.length > 1) {
              var lx = left;
              series.forEach(function (s, si) {
                out.push('<rect x="' + lx + '" y="6" width="10" height="10" rx="3" style="fill:' + color(si, s.color) + '"/>');
                out.push('<text x="' + (lx + 15) + '" y="11" dy="0.32em">' + esc(s.name) + "</text>");
                lx += 30 + s.name.length * 6.4;
              });
            }
            return title + out.join("") + "</svg>";
          }

          // chart(target, { kind: "line"|"area"|"bar"|"pie"|"donut", title, points: [{ label, value }]
          //   or series: [{ name, points }], format: "number"|"percent"|"currency"|"EUR"|fn, height, zero })
          // draws into target; calling it again with new data redraws it.
          function chart(target, spec) {
            var el = element(target);
            if (!el) return;
            el.classList.add("chart");
            el.__jarvisChart = spec || {};
            var draw = function () { el.innerHTML = plot(el.__jarvisChart, el.clientWidth || 320); };
            draw();
            if (!el.__jarvisObserver && window.ResizeObserver) {
              var width = el.clientWidth;
              el.__jarvisObserver = new ResizeObserver(function () {
                if (el.clientWidth !== width) { width = el.clientWidth; draw(); }
              });
              el.__jarvisObserver.observe(el);
            }
          }

          // Wide tables scroll sideways instead of widening the page.
          function wrapTables(root) {
            var tables = root.tagName === "TABLE" ? [root] : (root.querySelectorAll ? root.querySelectorAll("table") : []);
            Array.prototype.forEach.call(tables, function (t) {
              var parent = t.parentElement;
              if (!parent || parent.classList.contains("jd-scroll") || t.closest("[data-jarvis-raw]")) return;
              var wrap = document.createElement("div");
              wrap.className = "jd-scroll";
              parent.insertBefore(wrap, t);
              wrap.appendChild(t);
            });
          }

          document.addEventListener("DOMContentLoaded", function () {
            var off = document.querySelector('meta[name="jarvis-kit"]');
            if (off && /^(off|none|false)$/i.test(off.getAttribute("content") || "")) {
              var kit = document.getElementById("jarvis-kit");
              if (kit) kit.remove();
              return;
            }
            if (!document.body) return;
            wrapTables(document.body);
            new MutationObserver(function (changes) {
              changes.forEach(function (change) {
                change.addedNodes.forEach(function (node) { if (node.nodeType === 1) wrapTables(node); });
              });
            }).observe(document.body, { childList: true, subtree: true });
          });

          window.Jarvis = { version: 1, text: text, json: json, live: live, chart: chart, table: table, h: h, format: format };
        })();
        """#
}
