import WebKit

/// The look and helpers every document gets (`JarvisDocumentWebView`), offline, from the app's
/// `DocumentKit` folder: Tailwind CSS's browser build (utility classes), Basecoat (shadcn/ui's
/// design in plain HTML: cards, badges, buttons, alerts, tables, tabs) with its chart helper on
/// Chart.js, and Lucide icons. On top of them come a `prose` class for long-form writing, the page's
/// padding and light or dark mode (`html.dark`, from the phone's appearance), and `window.Jarvis`:
/// `live` re-renders from a JSON file JARVIS keeps current, `chart` draws or redraws a Basecoat
/// chart, `icons` draws Lucide icons in markup added later, and `json`, `text`, `h` and `format`
/// help build a page. Everything runs at document start, before the page's own scripts, so a
/// document uses it without a tag; `<meta name="jarvis-kit" content="off">` drops the stylesheets.
/// The platform note (`HermesREST.platformNote`) is how JARVIS learns these names: keep the two in
/// step. Versions and licenses are in THIRD_PARTY_NOTICES.md.
enum JarvisDocumentKit {
    /// The libraries in the order a page runs them: each one's dependencies first.
    static let libraries = ["tailwindcss-browser.js", "chart.umd.min.js", "basecoat.min.js", "basecoat-chart.min.js", "lucide.min.js"]
    static let stylesheet = "basecoat.min.css"
    static let folder = "DocumentKit"

    /// Built once: the libraries are about 1.2 MB of text.
    @MainActor static let userScripts: [WKUserScript] = {
        let loaded = Self.libraries.compactMap { name in Self.file(name).map { name == "tailwindcss-browser.js" ? Self.tailwind($0) : $0 } }
        return ([Self.bootstrap(stylesheet: Self.file(Self.stylesheet) ?? "")] + loaded + [Self.script])
            .map { WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true) }
    }()

    /// A file of the kit, or nil when the app doesn't carry it; the page then loads without it.
    static func file(_ name: String, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: folder) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Tailwind's build appends its stylesheet to `document.head` as it loads, and at document start
    /// a page has no head yet, so the document element holds it, after the kit's own styles.
    static func tailwind(_ source: String) -> String {
        source.replacingOccurrences(of: "document.head.append(", with: "(document.head||document.documentElement).append(")
    }

    /// The styles go in ahead of the document's own: Basecoat, then the kit's, then the Tailwind
    /// theme that names Basecoat's colors (`bg-muted`, `text-muted-foreground`, …). A document's own
    /// viewport tag, parsed later, replaces this one.
    static func bootstrap(stylesheet: String) -> String {
        """
        (function () {
          var root = document.documentElement;
          function add(tag, props) {
            var el = document.createElement(tag);
            Object.keys(props).forEach(function (key) { el[key] = props[key]; });
            root.appendChild(el);
          }
          add("style", { id: "jarvis-kit-basecoat", textContent: \(literal(stylesheet)) });
          add("style", { id: "jarvis-kit", textContent: \(literal(style)) });
          add("style", { type: "text/tailwindcss", textContent: \(literal(theme)) });
          add("meta", { name: "viewport", content: "width=device-width, initial-scale=1" });
          var dark = matchMedia("(prefers-color-scheme: dark)");
          function apply() { root.classList.toggle("dark", dark.matches); }
          apply();
          dark.addEventListener("change", apply);
        })();
        """
    }

    private static func literal(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    static let theme = #"""
        @theme inline {
          --color-background: var(--background);
          --color-foreground: var(--foreground);
          --color-card: var(--card);
          --color-card-foreground: var(--card-foreground);
          --color-popover: var(--popover);
          --color-popover-foreground: var(--popover-foreground);
          --color-primary: var(--primary);
          --color-primary-foreground: var(--primary-foreground);
          --color-secondary: var(--secondary);
          --color-secondary-foreground: var(--secondary-foreground);
          --color-muted: var(--muted);
          --color-muted-foreground: var(--muted-foreground);
          --color-accent: var(--accent);
          --color-accent-foreground: var(--accent-foreground);
          --color-destructive: var(--destructive);
          --color-border: var(--border);
          --color-input: var(--input);
          --color-ring: var(--ring);
          --color-chart-1: var(--chart-1);
          --color-chart-2: var(--chart-2);
          --color-chart-3: var(--chart-3);
          --color-chart-4: var(--chart-4);
          --color-chart-5: var(--chart-5);
        }
        @layer base {
          *, ::before, ::after { border-color: var(--border); }
        }
        """#

    /// The base rules are one step more specific than Tailwind's preflight, which comes later in the
    /// same layer; utilities, in a later layer, still win over both.
    static let style = #"""
        @layer base {
          :root:root {
            font: -apple-system-body;
            font-family: var(--default-font-family, ui-sans-serif, system-ui, sans-serif);
            line-height: 1.5;
          }
          html body {
            margin: 0 auto; max-width: 48rem; padding: 16px 16px 48px;
            background: var(--background); color: var(--foreground); -webkit-font-smoothing: antialiased;
          }
        }
        @layer components {
          .prose { line-height: 1.65; overflow-wrap: break-word; }
          .prose > :first-child { margin-top: 0; }
          .prose :where(h1) { font-size: 1.875rem; font-weight: 700; line-height: 1.2; letter-spacing: -0.02em; margin: 0.4em 0 0.5em; }
          .prose :where(h2) { font-size: 1.375rem; font-weight: 650; line-height: 1.3; letter-spacing: -0.01em; margin: 1.6em 0 0.5em; }
          .prose :where(h3) { font-size: 1.125rem; font-weight: 600; line-height: 1.35; margin: 1.4em 0 0.4em; }
          .prose :where(p) { margin: 0 0 0.9em; }
          .prose :where(ul, ol) { margin: 0 0 1em; padding-left: 1.4em; }
          .prose :where(ul) { list-style: disc; }
          .prose :where(ol) { list-style: decimal; }
          .prose :where(li) { margin: 0.25em 0; }
          .prose li::marker { color: var(--muted-foreground); }
          .prose :where(ul:has(> li > input[type="checkbox"])) { list-style: none; padding-left: 0.1em; }
          .prose :where(input[type="checkbox"]) { accent-color: var(--primary); margin-right: 0.45em; }
          .prose :where(a) { color: inherit; text-decoration: underline; text-decoration-color: var(--muted-foreground); text-underline-offset: 2px; }
          .prose :where(strong) { font-weight: 600; }
          .prose :where(blockquote) { margin: 1em 0; padding-left: 1em; border-left: 3px solid var(--border); color: var(--muted-foreground); }
          .prose :where(hr) { border: 0; border-top: 1px solid var(--border); margin: 2em 0; }
          .prose :where(code) { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.875em; background: var(--muted); padding: 0.15em 0.35em; border-radius: 0.3rem; }
          .prose :where(pre) { background: var(--muted); border-radius: 0.6rem; padding: 0.9em 1em; overflow-x: auto; font-size: 0.85em; line-height: 1.5; margin: 1em 0; }
          .prose :where(pre code) { background: none; padding: 0; font-size: 1em; }
          .prose :where(table) { width: 100%; border-collapse: collapse; font-size: 0.9em; margin: 1em 0; }
          .prose :where(th) { text-align: left; font-weight: 600; border-bottom: 1px solid var(--border); padding: 0.5em 0.75em; }
          .prose :where(td) { border-bottom: 1px solid var(--border); padding: 0.5em 0.75em; vertical-align: top; }
          .prose :where(img) { max-width: 100%; height: auto; border-radius: 0.6rem; }
          .prose :where(summary) { cursor: pointer; font-weight: 500; }
          .jd-scroll { overflow-x: auto; margin: 1em 0; }
          .jd-scroll > table { margin: 0; }
        }
        @media (prefers-reduced-motion: reduce) {
          *, ::before, ::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }
        }
        """#

    static let script = #"""
        (function () {
          "use strict";
          if (window.Jarvis) return;
          var reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
          if (window.Chart && reduceMotion.matches) window.Chart.defaults.animation = false;

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

          // Draws Lucide icons (<i data-lucide="name">) under root, the whole page by default.
          function icons(root) {
            if (window.lucide) window.lucide.createIcons(root ? { root: root } : undefined);
          }

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
                try { render(data); icons(); } catch (e) { console.error("Jarvis.live render", e); }
              }).catch(function (e) { console.warn("Jarvis.live", e); }).then(function () {
                busy = false;
                if (!stopped) timer = setTimeout(tick, every);
              });
            }
            document.addEventListener("visibilitychange", function () { if (!document.hidden) tick(); });
            tick();
            return { stop: function () { stopped = true; clearTimeout(timer); }, refresh: tick };
          }

          // basecoat.chart(target, config) on a <canvas> (or an element holding one). Drawing it
          // again replaces the chart without its entrance animation, so a live dashboard can redraw
          // from render(data) every time.
          function chart(target, config) {
            var el = typeof target === "string" ? document.querySelector(target) : target;
            if (!el || !window.basecoat || !window.basecoat.chart) return null;
            var canvas = el.tagName === "CANVAS" ? el : el.querySelector("canvas");
            var options = Object.assign({}, config || {});
            if (reduceMotion.matches || (canvas && window.Chart && window.Chart.getChart(canvas))) {
              options.options = Object.assign({}, options.options, { animation: false });
            }
            return window.basecoat.chart(el, options);
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

          document.addEventListener("DOMContentLoaded", function () {
            var off = document.querySelector('meta[name="jarvis-kit"]');
            if (off && /^(off|none|false)$/i.test(off.getAttribute("content") || "")) {
              ["jarvis-kit-basecoat", "jarvis-kit"].forEach(function (id) {
                var style = document.getElementById(id);
                if (style) style.remove();
              });
              return;
            }
            icons();
            // A wide table in prose scrolls sideways instead of widening the page.
            document.querySelectorAll(".prose table").forEach(function (t) {
              if (t.parentElement.classList.contains("jd-scroll")) return;
              var wrap = document.createElement("div");
              wrap.className = "jd-scroll";
              t.parentElement.insertBefore(wrap, t);
              wrap.appendChild(t);
            });
          });

          window.Jarvis = { version: 2, text: text, json: json, live: live, chart: chart, icons: icons, h: h, format: format };
        })();
        """#
}
