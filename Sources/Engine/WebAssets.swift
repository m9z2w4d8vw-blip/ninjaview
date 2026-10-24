import Foundation

/// Everything injected into tik.ninja's page. These three sources were tested
/// against saved copies of the site (October 2026). When tik.ninja changes its
/// markup, the selectors in `engineJS` are the place to update.
enum WebAssets {
    struct PageConfig: Encodable {
        let clean: Bool
        let noAds: Bool
        let theme: Bool
        let nativeProfiles: Bool
        let nativeDownloads: Bool
        /// Headers and the start of the answer for every tik.ninja request, not only refused ones.
        var verboseNet: Bool = false
    }

    /// The document-start script, with this page's settings and stylesheet baked in.
    static func documentStartSource(_ config: PageConfig) -> String {
        let configJSON = (try? JSONEncoder().encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let cssJSON = (try? JSONEncoder().encode(pageCSS)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "window.__nvConfig = \(configJSON);\nwindow.__nvCSS = \(cssJSON);\n" + documentStartJS
    }

    /// Ad and tracker hosts blocked at the network level (WKContentRuleList).
    static let blockedDomains = [
        "googlesyndication.com", "doubleclick.net", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com",
        "fundingchoicesmessages.google.com", "adtrafficquality.google", "imasdk.googleapis.com",
        "amazon-adsystem.com", "adnxs.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com", "33across.com", "moatads.com",
        "scorecardresearch.com", "quantserve.com", "hotjar.com", "clarity.ms", "connect.facebook.net",
        "analytics.tiktok.com", "cloudflareinsights.com", "propellerads.com", "popads.net", "popcash.net",
        "adsterra.com", "exoclick.com", "onclickads.net", "monetag.com", "a-ads.com", "hilltopads.net",
        "mgid.com", "revcontent.com", "mc.yandex.ru", "ezoic.net", "ezojs.com", "media.net",
        "sharethrough.com", "yieldmo.com", "smartadserver.com", "adform.net", "bidswitch.net", "lijit.com",
        "sovrn.com", "teads.tv", "doubleverify.com", "adsafeprotected.com", "id5-sync.com", "seedtag.com",
        "gumgum.com"
    ]

    static var blockListJSON: String {
        let rules = blockedDomains.map { (domain: String) -> [String: Any] in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?" + escaped + "[:/]"], "action": ["type": "block"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Cosmetic layer, used when the page itself is shown (Show tik.ninja page).
    static let pageCSS = #"""
/* NinjaView cosmetic layer over tik.ninja. Every rule is scoped to a class the
   bootstrap script puts on <html>, so Settings can switch each part off. */

html.nv-theme { color-scheme: light dark; }
html.nv-theme, html.nv-theme body { background: var(--bg) !important; }
html.nv-clean * { -webkit-tap-highlight-color: transparent; }

@media (prefers-color-scheme: light) {
  html.nv-theme {
    --bg: #f5f4f0 !important; --fg: #0f0f0f !important; --card: #ffffff !important;
    --border: #d8d6d0 !important; --muted: #6e6e6e !important; --accent: #ff2d55 !important;
  }
}
@media (prefers-color-scheme: dark) {
  html.nv-theme {
    --bg: #000000 !important; --fg: #f5f4f0 !important; --card: #141414 !important;
    --border: #2a2a2a !important; --muted: #9a9a9a !important; --accent: #ff375f !important;
  }
}

/* The app's own search, navigation and theme controls replace these. */
html.nv-clean .theme-toggle,
html.nv-clean .hero-eyebrow,
html.nv-clean .hero-title,
html.nv-clean .hero-subtitle,
html.nv-clean .search-wrap,
html.nv-clean .hero-tags,
html.nv-clean .viewer-back,
html.nv-clean #seo,
html.nv-clean footer { display: none !important; }

html.nv-clean .hero,
html.nv-clean .hero.compact { min-height: 0 !important; padding: 0 1rem !important; }
html.nv-clean #search-status { margin: .75rem 0 0 !important; min-height: 0 !important; }
html.nv-clean #viewer { padding: .75rem .75rem 2.5rem !important; }
html.nv-clean .profile-header { margin-bottom: 1rem !important; }
html.nv-clean .stats-panel { margin-bottom: 1rem !important; }
html.nv-clean .tab-btn { padding-top: .8rem !important; padding-bottom: .8rem !important; }
html.nv-clean .modal-back { padding: .75rem !important; }
html.nv-clean .go-top { bottom: 1rem !important; right: 1rem !important; }

/* Touch screens: hover overlays get stuck after a tap. */
@media (hover: none) {
  html.nv-clean .vcard-overlay { display: none !important; }
  html.nv-clean .vcard:hover img { transform: none !important; }
}

/* Ad slots. Ad networks are also blocked at the network level. */
html.nv-noads ins.adsbygoogle,
html.nv-noads .profile-ad-unit,
html.nv-noads #custom-vignette,
html.nv-noads .google-auto-placed,
html.nv-noads iframe[id^="aswift"],
html.nv-noads iframe[src*="googlesyndication"],
html.nv-noads iframe[src*="doubleclick"],
html.nv-noads iframe[src*="googleads"] { display: none !important; }
"""#

    /// Network logger plus the stylesheet and class bootstrap. Runs before tik.ninja's own scripts.
    /// The logger posts a "net" message for every fetch and XMLHttpRequest, "res" batches for the
    /// images and scripts the page loads, and "stream" messages for EventSource and WebSocket.
    static let documentStartJS = #"""
// Runs at document start, before the site's own scripts. Logs every request the page makes
// (method, status, time, size, URL). On tik.ninja it also keeps what was sent, the answer's
// headers, and the start of the answer whenever a request is refused or fails.
(function () {
  'use strict';
  if (window.__nvNet) return;
  window.__nvNet = true;
  var CFG = window.__nvConfig || {};
  function post(msg) { try { window.webkit.messageHandlers.nv.postMessage(msg); } catch (e) {} }
  var DETAIL = /(^|\.)tik\.ninja$/i.test(location.hostname);
  var VERBOSE = DETAIL && !!CFG.verboseNet;
  var seq = 0;
  // The last 80 answered requests and every unanswered one, read by the engine's lookup trace and
  // by diagnose(), so a failure report shows what the page asked for and what came back.
  var ring = [];
  var pending = {};
  window.__nvNetLog = ring;
  window.__nvNetPending = pending;
  window.__nvNetSeq = function () { return seq; };

  function parse(u) {
    try {
      var x = new URL(u, location.href);
      return { host: x.host, path: x.pathname, search: x.search, href: x.href };
    } catch (e) {
      var s = String(u || '');
      return { host: '', path: s.slice(0, 200), search: '', href: s };
    }
  }
  function shorten(p) { return p.host + p.path + (p.search ? p.search.slice(0, 300) : ''); }
  function cut(s, n) {
    s = String(s == null ? '' : s);
    return s.length > n ? s.slice(0, n) + '\u2026 (' + s.length + ' chars)' : s;
  }
  function squash(s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); }
  // Values that could identify a session are replaced by their length.
  var SECRET = /authorization|cookie|token|secret|csrf|xsrf|session|password|signature|api-?key/i;
  function scrub(headers) {
    Object.keys(headers).forEach(function (k) {
      headers[k] = SECRET.test(k) ? '***(' + String(headers[k]).length + ' chars)' : cut(headers[k], 300);
    });
    return headers;
  }
  function headerObject(h) {
    var out = {};
    if (!h) return out;
    try {
      if (typeof Headers !== 'undefined' && h instanceof Headers) h.forEach(function (v, k) { out[String(k).toLowerCase()] = String(v); });
      else if (Array.isArray(h)) h.forEach(function (pair) { if (pair && pair.length > 1) out[String(pair[0]).toLowerCase()] = String(pair[1]); });
      else if (typeof h === 'object') Object.keys(h).forEach(function (k) { out[k.toLowerCase()] = String(h[k]); });
    } catch (e) {}
    return scrub(out);
  }
  function bodyText(b) {
    if (b == null) return '';
    try {
      if (typeof b === 'string') return cut(b, 400);
      if (typeof URLSearchParams !== 'undefined' && b instanceof URLSearchParams) return cut(b.toString(), 400);
      if (typeof FormData !== 'undefined' && b instanceof FormData) {
        var parts = [];
        b.forEach(function (v, k) { parts.push(k + '=' + (typeof v === 'string' ? cut(v, 60) : '<file>')); });
        return 'form: ' + cut(parts.join('&'), 400);
      }
      if (typeof Blob !== 'undefined' && b instanceof Blob) return '<blob, ' + b.size + ' bytes, ' + (b.type || 'no type') + '>';
      if (typeof ArrayBuffer !== 'undefined' && (b instanceof ArrayBuffer || ArrayBuffer.isView(b))) return '<' + b.byteLength + ' bytes>';
      return '<' + Object.prototype.toString.call(b) + '>';
    } catch (e) { return ''; }
  }
  // Headers that say how close the connection is to a limit; sent with every request's line.
  var LIMIT = /^(retry-after|x-ratelimit.*|ratelimit.*|x-rate-limit.*|cf-mitigated)$/;
  function limitHeaders(all) {
    var out = {};
    Object.keys(all).forEach(function (k) { if (LIMIT.test(k)) out[k] = all[k]; });
    return out;
  }
  function begin(kind, method, url) {
    var info = { seq: ++seq, kind: kind, method: String(method || 'GET').toUpperCase(), p: parse(url), t0: Date.now(), ms: null };
    pending[info.seq] = { method: info.method, url: shorten(info.p), t0: info.t0 };
    return info;
  }
  // Called as soon as the status is known, so a lookup trace has it before the body is read.
  function answered(info, status, note) {
    delete pending[info.seq];
    info.ms = Date.now() - info.t0;
    ring.push({ seq: info.seq, at: Date.now(), ms: info.ms, method: info.method, url: shorten(info.p), status: status, note: note || '' });
    if (ring.length > 80) ring.shift();
  }
  function report(info, extra) {
    var msg = { type: 'net', seq: info.seq, kind: info.kind, method: info.method, url: shorten(info.p),
                host: info.p.host, path: info.p.path, ms: info.ms == null ? Date.now() - info.t0 : info.ms };
    Object.keys(extra).forEach(function (k) { msg[k] = extra[k]; });
    var failed = msg.status >= 400 || (msg.status === 0 && msg.rtype !== 'opaque');
    if (DETAIL && (failed || VERBOSE)) {
      if (info.reqHeaders && Object.keys(info.reqHeaders).length) msg.reqHeaders = info.reqHeaders;
      if (info.reqBody) msg.reqBody = info.reqBody;
    }
    post(msg);
  }
  function retryNote(all) { return all['retry-after'] ? 'retry-after ' + all['retry-after'] : ''; }

  if (typeof window.fetch === 'function') {
    var nativeFetch = window.fetch;
    window.fetch = function (input, init) {
      var info = null;
      try {
        var url = typeof input === 'string' ? input : (input && (input.url || input.href)) || String(input || '');
        info = begin('fetch', (init && init.method) || (input && input.method) || 'GET', url);
        if (DETAIL) {
          info.reqHeaders = headerObject((init && init.headers) || (input && input.headers));
          if (init && init.credentials) info.reqHeaders['(credentials)'] = String(init.credentials);
          if (init && init.mode) info.reqHeaders['(mode)'] = String(init.mode);
          if (init && init.cache) info.reqHeaders['(cache)'] = String(init.cache);
          info.reqBody = bodyText(init && init.body);
        }
      } catch (e) { info = null; }
      var request;
      try {
        request = nativeFetch.apply(window, arguments);
      } catch (e) {
        if (info) answered(info, 0, String((e && e.message) || e));
        throw e;
      }
      if (!info) return request;
      request.then(function (r) {
        var all = {};
        try { r.headers.forEach(function (v, k) { all[String(k).toLowerCase()] = String(v); }); } catch (e) {}
        scrub(all);
        var failed = r.status >= 400 || (r.status === 0 && r.type !== 'opaque');
        var extra = { status: r.status, statusText: r.statusText || '', rtype: r.type || '', size: Number(all['content-length']) || 0 };
        extra.resHeaders = DETAIL && (failed || VERBOSE) ? all : limitHeaders(all);
        if (r.redirected && r.url) extra.finalURL = shorten(parse(r.url));
        answered(info, r.status, retryNote(all));
        var type = all['content-type'] || '';
        var readable = DETAIL && (failed || VERBOSE) && r.type !== 'opaque' && extra.size < 300000 &&
          (!type || /json|text|html|xml|javascript/i.test(type));
        var copy = null;
        if (readable) { try { copy = r.clone(); } catch (e) { copy = null; } }
        if (!copy) { report(info, extra); return; }
        copy.text().then(function (t) {
          extra.body = cut(squash(t), failed ? 2000 : 400);
          if (!extra.size) extra.size = t.length;
          report(info, extra);
        }, function (e) {
          extra.body = '(couldn\u2019t read it: ' + String((e && e.message) || e) + ')';
          report(info, extra);
        });
      }, function (err) {
        var why = String((err && err.message) || err);
        answered(info, 0, why);
        report(info, { status: 0, error: why, online: navigator.onLine });
      }).catch(function () {});
      return request;
    };
  }
  if (window.XMLHttpRequest) {
    var proto = XMLHttpRequest.prototype, open = proto.open, sendXHR = proto.send, setHeader = proto.setRequestHeader;
    proto.open = function (method, url) {
      try { this.__nvInfo = { method: method, url: url, headers: {} }; } catch (e) {}
      return open.apply(this, arguments);
    };
    proto.setRequestHeader = function (name, value) {
      try { if (this.__nvInfo) this.__nvInfo.headers[String(name).toLowerCase()] = String(value); } catch (e) {}
      return setHeader.apply(this, arguments);
    };
    proto.send = function (body) {
      var xhr = this;
      try {
        var given = xhr.__nvInfo || { method: 'GET', url: '', headers: {} };
        var info = begin('xhr', given.method, given.url);
        if (DETAIL) { info.reqHeaders = headerObject(given.headers); info.reqBody = bodyText(body); }
        xhr.__nvCurrent = info;
        var reason = '';
        ['error', 'abort', 'timeout'].forEach(function (name) {
          xhr.addEventListener(name, function () { if (xhr.__nvCurrent === info) reason = name; });
        });
        xhr.addEventListener('loadend', function () {
          if (xhr.__nvCurrent !== info) return;
          var all = {};
          try {
            String(xhr.getAllResponseHeaders() || '').trim().split(/[\r\n]+/).forEach(function (line) {
              var at = line.indexOf(':');
              if (at > 0) all[line.slice(0, at).trim().toLowerCase()] = line.slice(at + 1).trim();
            });
          } catch (e) {}
          scrub(all);
          var status = xhr.status;
          var failed = status === 0 || status >= 400;
          var text = '';
          try {
            if (!xhr.responseType || xhr.responseType === 'text') text = String(xhr.responseText || '');
            else if (xhr.responseType === 'json' && xhr.response != null) text = JSON.stringify(xhr.response);
          } catch (e) { text = ''; }
          var extra = { status: status, statusText: xhr.statusText || '', size: Number(all['content-length']) || text.length };
          extra.resHeaders = DETAIL && (failed || VERBOSE) ? all : limitHeaders(all);
          if (reason) extra.error = reason;
          if (xhr.responseURL && xhr.responseURL !== info.p.href) extra.finalURL = shorten(parse(xhr.responseURL));
          if (DETAIL && text && (failed || VERBOSE)) extra.body = cut(squash(text), failed ? 2000 : 400);
          answered(info, status, reason || retryNote(all));
          report(info, extra);
        });
      } catch (e) {}
      return sendXHR.apply(this, arguments);
    };
  }
  // Streaming connections, in case tik.ninja's search ever uses one.
  if (DETAIL && typeof window.EventSource === 'function') {
    try {
      var NativeES = window.EventSource;
      window.EventSource = class EventSource extends NativeES {
        constructor(url, config) {
          super(url, config);
          var es = this, p = parse(url), t0 = Date.now(), id = ++seq, count = 0, errors = 0;
          var tell = function (event, more) {
            var msg = { type: 'stream', kind: 'sse', seq: id, event: event, url: shorten(p), host: p.host, path: p.path, ms: Date.now() - t0 };
            if (more) Object.keys(more).forEach(function (k) { msg[k] = more[k]; });
            post(msg);
          };
          tell('connect');
          es.addEventListener('open', function () { tell('open'); });
          es.addEventListener('message', function (e) { count += 1; if (count <= 3) tell('message', { data: cut(squash(e.data), 300), count: count }); });
          es.addEventListener('error', function () { errors += 1; if (errors <= 5) tell('error', { state: es.readyState, count: count }); });
        }
      };
    } catch (e) {}
  }
  if (DETAIL && typeof window.WebSocket === 'function') {
    try {
      var NativeWS = window.WebSocket;
      window.WebSocket = class WebSocket extends NativeWS {
        constructor(url, protocols) {
          if (protocols === undefined) super(url); else super(url, protocols);
          var ws = this, p = parse(url), t0 = Date.now(), id = ++seq, count = 0;
          var tell = function (event, more) {
            var msg = { type: 'stream', kind: 'ws', seq: id, event: event, url: shorten(p), host: p.host, path: p.path, ms: Date.now() - t0 };
            if (more) Object.keys(more).forEach(function (k) { msg[k] = more[k]; });
            post(msg);
          };
          tell('connect');
          ws.addEventListener('open', function () { tell('open'); });
          ws.addEventListener('message', function (e) {
            count += 1;
            if (count <= 3) tell('message', { data: typeof e.data === 'string' ? cut(squash(e.data), 300) : '<binary>', count: count });
          });
          ws.addEventListener('close', function (e) { tell('close', { code: e.code, reason: e.reason || '', count: count }); });
          ws.addEventListener('error', function () { tell('error', { state: ws.readyState, count: count }); });
        }
      };
    } catch (e) {}
  }
  // Images, scripts, fonts and the like, batched every five seconds. The tik.ninja ones (its image
  // proxy, for one) count toward its limit as much as any fetch.
  if (DETAIL && typeof PerformanceObserver === 'function') {
    var batch = [], others = {}, flushTimer = null;
    var flushResources = function () {
      flushTimer = null;
      if (!batch.length && !Object.keys(others).length) return;
      post({ type: 'res', items: batch, others: others });
      batch = [];
      others = {};
    };
    try {
      new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (e) {
          var kind = e.initiatorType || 'other';
          if (kind === 'fetch' || kind === 'xmlhttprequest' || kind === 'beacon') return; // logged above
          var p = parse(e.name);
          if (/(^|\.)tik\.ninja$/i.test(p.host)) {
            if (batch.length < 300) {
              batch.push({ host: p.host, path: p.path, kind: kind, ms: Math.round(e.duration || 0),
                           size: e.transferSize || 0, status: e.responseStatus || 0 });
            }
          } else {
            var key = (p.host || 'unknown') + ' ' + kind;
            others[key] = (others[key] || 0) + 1;
          }
        });
        if (!flushTimer) flushTimer = setTimeout(flushResources, 5000);
      }).observe({ type: 'resource', buffered: true });
    } catch (e) {}
  }
  // Console warnings and errors from the site's own scripts.
  ['warn', 'error'].forEach(function (level) {
    var original = console[level];
    if (typeof original !== 'function') return;
    console[level] = function () {
      try {
        var parts = Array.prototype.map.call(arguments, function (a) {
          if (a instanceof Error) return a.message;
          if (a && typeof a === 'object') { try { return JSON.stringify(a).slice(0, 300); } catch (e) { return String(a); } }
          return String(a);
        });
        post({ type: 'log', level: level, message: 'console.' + level + ': ' + parts.join(' ').slice(0, 600) });
      } catch (e) {}
      return original.apply(console, arguments);
    };
  });
})();
// Runs at document start, before tik.ninja's own scripts.
(function () {
  'use strict';
  if (window.__nvBooted) return;
  window.__nvBooted = true;

  var CFG = window.__nvConfig || {};
  var wanted = [];
  if (CFG.clean) wanted.push('nv-clean');
  if (CFG.noAds) wanted.push('nv-noads');
  if (CFG.theme) wanted.push('nv-theme');

  // WebKit creates <html> before document-start scripts run; other engines
  // may not, so wait for it if needed.
  function whenRoot(fn) {
    if (document.documentElement) { fn(document.documentElement); return; }
    var mo = new MutationObserver(function () {
      if (document.documentElement) { mo.disconnect(); fn(document.documentElement); }
    });
    mo.observe(document, { childList: true });
  }

  // Constructable stylesheets aren't subject to a page's style-src CSP;
  // fall back to a <style> element where they're unavailable.
  var css = window.__nvCSS || '';
  var adopted = false;
  try {
    if ('adoptedStyleSheets' in Document.prototype && typeof CSSStyleSheet === 'function') {
      var sheet = new CSSStyleSheet();
      sheet.replaceSync(css);
      document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
      adopted = true;
    }
  } catch (e) {
    adopted = false;
  }

  whenRoot(function (root) {
    function applyClasses() {
      for (var i = 0; i < wanted.length; i++) {
        if (!root.classList.contains(wanted[i])) root.classList.add(wanted[i]);
      }
    }
    applyClasses();
    if (!adopted) {
      var style = document.createElement('style');
      style.id = 'nv-style';
      style.textContent = css;
      (document.head || root).appendChild(style);
    }
    // The site may rewrite <html class> (its own theme toggle, for one). Keep ours.
    new MutationObserver(applyClasses).observe(root, { attributes: true, attributeFilter: ['class'] });
  });
})();
"""#

    /// The engine: window.__nv, which the app calls through callAsyncJavaScript.
    static let engineJS = #"""
// NinjaView engine. Runs at document end inside an off-screen copy of tik.ninja.
// The app drives it through window.__nv (via callAsyncJavaScript) and renders
// every result in SwiftUI. Selectors match tik.ninja's markup as of Oct 2026.
(function () {
  'use strict';
  if (window.__nv) return;
  var CFG = window.__nvConfig || {};

  // ---- helpers ---------------------------------------------------------------
  function post(type, payload) {
    var msg = payload || {};
    msg.type = type;
    try { window.webkit.messageHandlers.nv.postMessage(msg); } catch (e) { /* outside the app */ }
  }
  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function $$(sel, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(sel)); }
  function byId(id) { return document.getElementById(id); }
  function raw(el) { return el ? String(el.textContent || '').replace(/\s+/g, ' ').trim() : ''; }
  function lines(el) {
    return el ? String(el.textContent || '').replace(/[ \t\u00a0]+/g, ' ').replace(/ ?\n ?/g, '\n').replace(/\n{3,}/g, '\n\n').trim() : '';
  }
  function absolute(u) { if (!u) return ''; try { return new URL(u, location.href).href; } catch (e) { return ''; } }
  function httpOnly(u) { return /^https?:/i.test(u || '') ? u : ''; }
  function imgSrc(img) { return img ? absolute(img.currentSrc || img.getAttribute('src') || img.getAttribute('data-src') || '') : ''; }
  function shown(el) { return !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden'; }
  function sleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }
  async function until(fn, timeout, every) {
    var start = Date.now();
    for (;;) {
      var value = null;
      try { value = fn(); } catch (e) { value = null; }
      if (value) return value;
      if (Date.now() - start >= timeout) return null;
      await sleep(every || 100);
    }
  }

  // ---- diagnostics, shown in Settings > Debug log ------------------------------
  // The latest script errors, kept for diagnose() as well as logged.
  var recentErrors = [];
  function noteError(text) {
    recentErrors.push(new Date().toISOString().slice(11, 23) + '  ' + text);
    if (recentErrors.length > 15) recentErrors.shift();
  }
  window.addEventListener('error', function (e) {
    var where = e.filename ? ' (' + String(e.filename).split('/').pop() + ':' + e.lineno + ')' : '';
    var text = String(e.message || 'Script error') + where;
    noteError(text);
    post('log', { message: text });
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    var text = 'Unhandled rejection: ' + String((r && r.message) || r);
    noteError(text);
    post('log', { message: text });
  });
  function clip(s, n) {
    s = String(s == null ? '' : s);
    return s.length > n ? s.slice(0, n) + '\u2026 (' + s.length + ' chars)' : s;
  }

  // ---- lookup traces -------------------------------------------------------------
  // Each step of a lookup with its time since the lookup began, merged at the end with every
  // request the page answered (or is still waiting on) since then.
  function note(trace, text) { if (trace) trace.steps.push({ ms: Date.now() - trace.t0, text: text }); }
  function pad(ms) {
    var s = String(Math.max(0, Math.round(ms)));
    while (s.length < 6) s = ' ' + s;
    return '+' + s + ' ms';
  }
  function netSeq() { return typeof window.__nvNetSeq === 'function' ? window.__nvNetSeq() : 0; }
  function traceLines(trace, seq0) {
    var rows = trace.steps.slice();
    (window.__nvNetLog || []).forEach(function (n) {
      if (n.seq <= seq0) return;
      rows.push({ ms: n.at - trace.t0, text: '\u2190 ' + n.method + ' ' + (n.status || 'failed') + ' ' + n.url +
        ' (sent at +' + Math.max(0, n.at - n.ms - trace.t0) + ' ms, answered in ' + n.ms + ' ms' + (n.note ? ', ' + n.note : '') + ')' });
    });
    var open = window.__nvNetPending || {};
    Object.keys(open).forEach(function (k) {
      if (Number(k) <= seq0) return;
      var q = open[k];
      rows.push({ ms: Date.now() - trace.t0, text: 'still waiting: ' + q.method + ' ' + q.url + ' (sent at +' + Math.max(0, q.t0 - trace.t0) + ' ms)' });
    });
    rows.sort(function (a, b) { return a.ms - b.ms; });
    return rows.map(function (r) { return pad(r.ms) + '  ' + r.text; });
  }

  // ---- profile header ----------------------------------------------------------
  function readProfile() {
    var handle = raw($('#viewer-body .profile-handle') || $('.profile-handle')).replace(/^@+/, '');
    if (!handle) return null;
    return {
      handle: handle,
      name: raw($('.profile-name')),
      bio: lines($('.profile-bio')),
      avatar: imgSrc($('.profile-avatar')),
      stats: $$('.profile-stats .stat-link').map(function (cell) {
        return { label: raw($('.stat-lbl', cell)), value: raw($('.stat-num', cell)) };
      }).filter(function (s) { return s.label; })
    };
  }

  // ---- events the app listens to while a lookup runs ---------------------------
  var last = { handle: null, status: null, modal: null };
  function scan() {
    var p = readProfile();
    var key = p ? p.handle.toLowerCase() : '';
    if (key !== last.handle) { last.handle = key; if (p) post('profile', p); }
    var status = raw(byId('search-status'));
    if (status !== last.status) { last.status = status; post('status', { text: status }); }
    var open = modalOpen();
    if (open !== last.modal) { last.modal = open; post('modal', { open: open }); }
    dismissVignette();
  }
  var queued = false;
  function schedule() {
    if (queued) return;
    queued = true;
    setTimeout(function () {
      queued = false;
      try { scan(); } catch (e) { post('log', { message: 'scan: ' + e.message }); }
    }, 80);
  }
  // tik.ninja's own interstitial; with ads blocked it would be an empty overlay.
  function dismissVignette() {
    if (!CFG.noAds) return;
    var v = byId('custom-vignette');
    if (!v || v.style.display === 'none') return;
    var buttons = $$('button, [role="button"], [class*="close"]', v);
    for (var i = 0; i < buttons.length; i++) {
      if (!buttons[i].disabled) { buttons[i].click(); return; }
    }
  }

  // ---- search ------------------------------------------------------------------
  function setValue(input, value) {
    var desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    if (desc && desc.set) desc.set.call(input, value); else input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function closeOverlays() {
    if (commentsOpen()) { var cx = $('#comments-panel .modal-x'); if (cx) cx.click(); }
    if (modalOpen()) { var x = $('#modal .modal-x'); if (x) x.click(); }
  }
  function search(query, trace) {
    var input = byId('search-input');
    var button = byId('search-btn');
    if (!input || !button) {
      note(trace, 'search box ' + (input ? 'found' : 'missing') + ', Search button ' + (button ? 'found' : 'missing') + ' on ' + location.href);
      return 'not-ready';
    }
    closeOverlays();
    last.handle = null;
    last.status = null;
    setValue(input, query);
    note(trace, 'typed ' + JSON.stringify(query) + ' into the search box' +
      (button.disabled ? '; the Search button is disabled (an earlier lookup may still be running)' : ''));
    var tries = 0, waitStart = Date.now();
    (function go() {
      // The site disables the button while a lookup is in flight.
      if (button.disabled && tries++ < 60) { setTimeout(go, 125); return; }
      var waited = Date.now() - waitStart;
      note(trace, button.disabled ? 'the Search button was still disabled after ' + waited + ' ms; clicked it anyway'
        : (waited > 50 ? 'clicked Search after waiting ' + waited + ' ms for the button' : 'clicked Search'));
      button.click();
    })();
    return 'ok';
  }
  function looksLikeError(s) {
    return /not found|no user|doesn.?t exist|does not exist|private|error|failed|unable|couldn.?t|could not|invalid|limit|try again|unavailable|blocked|banned|suspended/i.test(s);
  }
  async function lookup(query) {
    var trace = { t0: Date.now(), steps: [] };
    var seq0 = netSeq();
    note(trace, 'lookup started on ' + location.href + ', ' + Math.round(performance.now()) + ' ms after the page began loading');
    var started = search(query, trace);
    if (started !== 'ok') return { profile: null, item: null, status: '', error: started, trace: traceLines(trace, seq0) };
    var t0 = Date.now();
    var seen = null;
    var outcome = await until(function () {
      var s = raw(byId('search-status'));
      if (s !== seen) { seen = s; note(trace, 'status line: ' + (s ? '\u201c' + s + '\u201d' : '(empty)')); }
      if (readProfile() || (modalOpen() && mediaSrc())) return 'found';
      if (s && looksLikeError(s) && Date.now() - t0 > 400) return 'error';
      return null;
    }, 30000, 120);
    if (outcome === 'found') {
      var shownProfile = readProfile();
      note(trace, shownProfile ? 'the profile header appeared (@' + shownProfile.handle + ')' : 'a post opened');
      // A pasted post link also opens that post once the profile renders.
      if (/^https?:/i.test(query) && !modalOpen()) {
        await until(function () { return modalOpen() && mediaSrc() ? true : null; }, 1500, 100);
      }
      var item = modalOpen() ? await readItem() : null;
      return { profile: readProfile(), item: item, status: '', error: '', trace: traceLines(trace, seq0) };
    }
    note(trace, outcome === 'error' ? 'stopped: the status line shows an error' : 'stopped: no profile and no error after 30 s');
    return { profile: null, item: null, status: raw(byId('search-status')), error: outcome === 'error' ? 'status' : 'timeout',
             trace: traceLines(trace, seq0) };
  }

  // ---- tabs --------------------------------------------------------------------
  var USER_TABS = { followers: true, following: true };
  function panel(name) { return byId('tab-panel-' + name); }
  function cardsIn(p) {
    var cards = $$('.vcard', p);
    if (cards.length) return cards;
    // Unknown card markup (highlights, say): any image-bearing child of a grid.
    var out = [];
    $$('[class*="grid"]', p).forEach(function (g) {
      Array.prototype.forEach.call(g.children, function (c) {
        if (c.querySelector('img') && !c.classList.contains('ucard')) out.push(c);
      });
    });
    return out;
  }
  function postFrom(card, i) {
    var known = card.classList.contains('vcard');
    return {
      index: i,
      thumb: imgSrc($('img', card)),
      badge: raw($('.vcard-badge', card)),
      duration: raw($('.vcard-dur', card)),
      date: raw($('.vcard-date', card)),
      plays: raw($('.vcard-plays', card)).replace(/^[\u25b6\u25ba]\s*/, ''),
      title: known ? '' : raw(card)
    };
  }
  function userFrom(card, i) {
    return {
      index: i,
      handle: raw($('.ucard-name', card)).replace(/^@+/, ''),
      nick: raw($('.ucard-nick', card)),
      stat: raw($('.ucard-stat', card)),
      avatar: imgSrc($('img', card))
    };
  }
  function leftover(p) {
    var c = p.cloneNode(true);
    $$('.grid-hdr, .tab-loading, .grid-end, .load-more-row, .video-grid, .user-grid, button, script, style', c)
      .forEach(function (e) { e.remove(); });
    return raw(c);
  }
  function tabState(name) {
    var p = panel(name);
    var s = { tab: name, exists: !!p, rendered: false, loading: false, hasMore: false, ended: false,
              endText: '', items: [], users: [], message: '' };
    if (!p) return s;
    s.rendered = !!p.firstElementChild;
    s.loading = shown($('.tab-loading', p));
    var more = $('.load-more-btn', p);
    s.hasMore = !!(more && shown(more) && !more.disabled);
    var end = $('.grid-end', p);
    s.ended = shown(end);
    s.endText = s.ended ? raw(end) : '';
    if (USER_TABS[name]) s.users = $$('.ucard', p).map(userFrom);
    else s.items = cardsIn(p).map(postFrom);
    if (!s.items.length && !s.users.length && s.rendered && !s.loading) s.message = leftover(p);
    return s;
  }
  async function openTab(name) {
    var button = byId('tab-btn-' + name);
    if (!button) return tabState(name);
    if (!button.classList.contains('active')) button.click();
    await until(function () { var p = panel(name); return p && shown(p) && p.firstElementChild ? true : null; }, 8000);
    await until(function () {
      var s = tabState(name);
      return (!s.loading && (s.items.length || s.users.length || s.ended || s.hasMore || s.message)) ? true : null;
    }, 20000, 120);
    await sleep(120);
    return tabState(name);
  }
  async function loadMore(name) {
    var p = panel(name);
    if (!p) return tabState(name);
    // The page may be showing another tab (stories preload, a background download).
    if (!shown(p)) { await openTab(name); p = panel(name); }
    var before = tabState(name);
    var count = before.items.length + before.users.length;
    var more = $('.load-more-btn', p);
    if (more && shown(more) && !more.disabled) more.click();
    else { window.scrollTo(0, document.documentElement.scrollHeight); window.dispatchEvent(new Event('scroll')); }
    var t0 = Date.now();
    await until(function () {
      var s = tabState(name);
      var n = s.items.length + s.users.length;
      return (n > count || s.ended || (!s.loading && Date.now() - t0 > 1500)) ? true : null;
    }, 20000, 120);
    await sleep(80);
    return tabState(name);
  }

  // ---- posts (the site's modal) ------------------------------------------------
  function modalOpen() { var m = byId('modal'); return !!(m && m.classList.contains('open')); }
  function mediaSrc() {
    var v = $('#modal-media-content video');
    if (v) {
      var s = v.currentSrc || v.getAttribute('src') || '';
      if (!s) { var so = $('source', v); if (so) s = so.getAttribute('src') || ''; }
      return httpOnly(absolute(s));
    }
    var img = byId('m-img') || $('#modal-media-content img');
    return img ? httpOnly(imgSrc(img)) : '';
  }
  function captionText() {
    var cap = byId('modal-cap');
    if (!cap) return '';
    var c = cap.cloneNode(true);
    $$('button', c).forEach(function (b) { b.remove(); });
    return lines(c);
  }
  function emptyItem(error) {
    return { kind: 'unknown', title: '', caption: '', stats: [], hasAudio: false, hasComments: false,
             video: '', poster: '', photos: [], error: error || '' };
  }
  function photoCount() {
    var m = raw(byId('mcount')).match(/(\d+)\s*\/\s*(\d+)/);
    return m ? { at: +m[1], of: +m[2] } : null;
  }
  async function stepPhoto(id) {
    var b = byId(id);
    if (!b || b.disabled) return false;
    var src = mediaSrc(), count = raw(byId('mcount'));
    b.click();
    await until(function () { return (mediaSrc() !== src || raw(byId('mcount')) !== count) ? true : null; }, 2000, 50);
    return true;
  }
  async function collectPhotos() {
    var c = photoCount();
    if (!c || c.of <= 1) { var one = mediaSrc(); return one ? [one] : []; }
    for (var g = 0; g < c.of && (photoCount() || { at: 1 }).at > 1; g++) {
      if (!(await stepPhoto('mprev'))) break;
    }
    var urls = [];
    for (var i = 0; i < c.of; i++) {
      var s = mediaSrc();
      if (s && urls.indexOf(s) === -1) urls.push(s);
      if (i < c.of - 1 && !(await stepPhoto('mnext'))) break;
    }
    return urls;
  }
  function quietMedia() {
    $$('#modal-media-content video').forEach(function (v) { try { v.pause(); v.muted = true; } catch (e) {} });
  }
  async function readItem() {
    if (!modalOpen()) return emptyItem('closed');
    var toggle = $('#modal-cap .modal-caption-toggle');
    if (toggle && /more/i.test(toggle.textContent || '')) { toggle.click(); await sleep(60); }
    var item = emptyItem('');
    item.title = raw(byId('modal-title'));
    item.caption = captionText();
    item.stats = $$('#modal-stats > div').map(function (d) {
      return { label: raw($('.m-stat-lbl', d)), value: raw($('.m-stat-num', d)) };
    }).filter(function (s) { return s.label; });
    var labels = $$('#modal-dl-bar .dl-btn').map(function (b) { return raw(b); });
    item.hasAudio = labels.some(function (t) { return /audio/i.test(t); });
    var section = byId('modal-comments-section');
    item.hasComments = !!byId('modal-comments-toggle') && !!section && section.style.display !== 'none';
    var v = $('#modal-media-content video');
    if (v) {
      item.kind = 'video';
      item.video = mediaSrc();
      item.poster = httpOnly(absolute(v.getAttribute('poster') || ''));
    } else if (byId('m-img') || $('#modal-media-content img')) {
      item.kind = 'photos';
      item.photos = await collectPhotos();
    }
    quietMedia();
    return item;
  }
  async function closeItem() {
    await closeComments();
    if (!modalOpen()) return 'ok';
    var x = $('#modal .modal-x');
    if (x) x.click();
    await until(function () { return !modalOpen() ? true : null; }, 2000, 50);
    return 'ok';
  }
  async function openItem(name, index) {
    var p = panel(name);
    if (!p || !shown(p)) { await openTab(name); p = panel(name); }
    var cards = p ? cardsIn(p) : [];
    if (index < 0 || index >= cards.length) return emptyItem('missing');
    var prevSrc = mediaSrc(), prevCaption = captionText();
    await closeItem();
    var card = cards[index];
    try { card.scrollIntoView({ block: 'center' }); } catch (e) {}
    // Click a child so the event bubbles through whichever element the site listens on.
    ($('.vcard-overlay', card) || $('img', card) || card).click();
    var opened = await until(function () { return modalOpen() && mediaSrc() ? true : null; }, 15000, 80);
    if (!opened) return modalOpen() ? await readItem() : emptyItem('timeout');
    if (mediaSrc() === prevSrc && captionText() === prevCaption) {
      await until(function () { return (mediaSrc() !== prevSrc || captionText() !== prevCaption) ? true : null; }, 3000, 80);
    }
    return await readItem();
  }
  function requestAudio() {
    var b = $$('#modal-dl-bar .dl-btn').filter(function (x) { return /audio/i.test(x.textContent || ''); })[0];
    if (!b) return { ok: false };
    b.click();
    return { ok: true };
  }

  // ---- comments ----------------------------------------------------------------
  function commentsOpen() { var c = byId('comments-panel'); return !!(c && c.classList.contains('open')); }
  function commentFrom(el, i) {
    var body = $(':scope > .comment-body', el);
    var meta = raw(body && $(':scope > .comment-meta', body));
    var likes = '', time = meta;
    var m = meta.match(/^\u2665\s*([^\u00b7]*?)\s*\u00b7\s*(.*)$/);
    if (m) { likes = m[1]; time = m[2]; }
    else if (/^\u2665/.test(meta)) { likes = meta.replace(/^\u2665\s*/, ''); time = ''; }
    var button = body && $(':scope > .reply-load-btn', body);
    var label = button ? raw(button) : '';
    var thread = body && $(':scope > .reply-thread', body);
    var open = !!(thread && thread.style.display !== 'none' && $(':scope > .comment-item', thread));
    var moreReplies = false;
    if (open) {
      $$('button', thread).forEach(function (b) {
        if (b.closest('.comment-item') === el && /more|load|view/i.test(b.textContent || '') && !b.disabled) moreReplies = true;
      });
    }
    return {
      index: i,
      handle: raw(body && $(':scope > .comment-user', body)).replace(/^@+/, ''),
      text: lines(body && $(':scope > .comment-text', body)),
      avatar: imgSrc($(':scope > .comment-avatar', el)),
      likes: likes,
      time: time,
      replyLabel: /hide/i.test(label) ? '' : label.replace(/^[^0-9A-Za-z]+/, ''),
      repliesOpen: open,
      repliesMore: moreReplies,
      replies: open ? $$(':scope > .comment-item', thread).map(commentFrom) : []
    };
  }
  function moreButton(scope) {
    var found = null;
    if (!scope) return null;
    $$('button', scope).forEach(function (b) {
      if (b.classList.contains('reply-load-btn') || b.closest('.reply-thread')) return;
      if (/more|load/i.test(b.textContent || '') && !b.disabled && shown(b)) found = b;
    });
    return found;
  }
  function commentList() { return byId('comments-list-inner') || $('#modal-comments-body .comments-list'); }
  function commentsState(error) {
    var body = byId('modal-comments-body');
    var list = commentList();
    var note = '';
    if (body) {
      var c = body.cloneNode(true);
      $$('.comments-list, #comments-list-inner, button', c).forEach(function (e) { e.remove(); });
      note = raw(c);
    }
    return {
      open: commentsOpen(),
      comments: list ? $$(':scope > .comment-item', list).map(commentFrom) : [],
      hasMore: !!moreButton(body),
      note: note,
      error: error || ''
    };
  }
  function listSignature() {
    var list = commentList();
    return list ? list.childElementCount + '|' + raw(list.firstElementChild) : '';
  }
  async function openComments() {
    var toggle = byId('modal-comments-toggle');
    if (!modalOpen() || !toggle) return commentsState('unavailable');
    var stale = listSignature();
    if (!commentsOpen()) toggle.click();
    var t0 = Date.now();
    await until(function () {
      if (!commentsOpen()) return null;
      if (stale && listSignature() === stale && Date.now() - t0 < 1500) return null;
      var s = commentsState('');
      return (s.comments.length || (s.note && !/loading/i.test(s.note))) ? true : null;
    }, 20000, 120);
    await sleep(100);
    return commentsState('');
  }
  async function moreComments() {
    var n = commentsState('').comments.length;
    var body = byId('modal-comments-body');
    var more = moreButton(body);
    if (more) more.click();
    else if (body) { body.scrollTop = body.scrollHeight; body.dispatchEvent(new Event('scroll')); }
    var t0 = Date.now();
    await until(function () {
      var s = commentsState('');
      return (s.comments.length > n || (Date.now() - t0 > 2500 && !/loading/i.test(s.note))) ? true : null;
    }, 15000, 120);
    return commentsState('');
  }
  function topComment(i) { var list = commentList(); return list ? ($$(':scope > .comment-item', list)[i] || null) : null; }
  async function openReplies(i) {
    var el = topComment(i);
    if (!el) return null;
    var body = $(':scope > .comment-body', el);
    var button = body && $(':scope > .reply-load-btn', body);
    var isOpen = function () {
      var th = body && $(':scope > .reply-thread', body);
      return th && th.style.display !== 'none' && $(':scope > .comment-item', th) ? true : null;
    };
    if (!isOpen() && button && !button.disabled) button.click();
    await until(isOpen, 15000, 100);
    await sleep(60);
    return commentFrom(topComment(i) || el, i);
  }
  async function moreReplies(i) {
    var el = topComment(i);
    if (!el) return null;
    var body = $(':scope > .comment-body', el);
    var thread = body && $(':scope > .reply-thread', body);
    var before = thread ? $$(':scope > .comment-item', thread).length : 0;
    var more = null;
    if (thread) $$('button', thread).forEach(function (b) {
      if (b.closest('.comment-item') === el && /more|load|view/i.test(b.textContent || '') && !b.disabled) more = b;
    });
    if (more) {
      more.click();
      await until(function () {
        var th = body && $(':scope > .reply-thread', body);
        return th && $$(':scope > .comment-item', th).length > before ? true : null;
      }, 15000, 100);
    }
    return commentFrom(topComment(i) || el, i);
  }
  async function closeComments() {
    if (!commentsOpen()) return 'ok';
    var x = $('#comments-panel .modal-x');
    if (x) x.click();
    await until(function () { return !commentsOpen() ? true : null; }, 1500, 50);
    return 'ok';
  }

  // ---- account analytics -------------------------------------------------------
  async function analytics() {
    var box = byId('stats-panel');
    if (!box) return { lines: [], error: 'missing' };
    var toggle = $('.stats-panel-toggle', box);
    if (toggle && toggle.getAttribute('aria-expanded') !== 'true') toggle.click();
    await until(function () {
      var b = $('.stats-panel-body', box);
      var t = raw(b);
      return t && !/^loading/i.test(t) ? true : null;
    }, 15000, 120);
    var body = $('.stats-panel-body', box);
    var out = body ? String(body.innerText || body.textContent || '').split('\n')
      .map(function (l) { return l.trim(); }).filter(Boolean) : [];
    return { lines: out, error: '' };
  }

  // ---- real taps, when the page itself is on screen ----------------------------
  function mediaBaseName() {
    var bar = byId('modal-dl-bar');
    var parts = [];
    if (bar && bar.dataset.uname) parts.push(bar.dataset.uname);
    if (bar && bar.dataset.vid) parts.push(bar.dataset.vid);
    return parts.join('_') || 'tiktok';
  }
  document.addEventListener('click', function (e) {
    if (!e.isTrusted) return; // the engine's own clicks pass straight through
    var t = e.target;
    if (!t || !t.closest) return;
    if (CFG.nativeProfiles) {
      var person = t.closest('.ucard, .comment-user');
      if (person) {
        var nameEl = person.classList.contains('ucard') ? $('.ucard-name', person) : person;
        var handle = raw(nameEl).replace(/^@+/, '');
        if (handle) { e.preventDefault(); e.stopImmediatePropagation(); post('openProfile', { handle: handle }); }
        return;
      }
    }
    if (CFG.nativeDownloads) {
      var dl = t.closest('.dl-btn');
      if (dl && dl.closest('#modal-dl-bar')) {
        var label = raw(dl).toLowerCase();
        var url = '', kind = '';
        if (label.indexOf('video') !== -1) { url = mediaSrc(); kind = 'video'; }
        else if (label.indexOf('photo') !== -1) { url = mediaSrc(); kind = 'photo'; }
        if (url) {
          e.preventDefault();
          e.stopImmediatePropagation();
          post('download', { url: url, kind: kind, name: mediaBaseName() });
        }
      }
    }
  }, true);
  var sx = 0, sy = 0, st = 0;
  document.addEventListener('touchstart', function (e) {
    var t = e.target;
    if (!t || !t.closest || !t.closest('#modal-media') || e.touches.length !== 1) { st = 0; return; }
    sx = e.touches[0].clientX; sy = e.touches[0].clientY; st = Date.now();
  }, { passive: true });
  document.addEventListener('touchend', function (e) {
    if (!st) return;
    var touch = e.changedTouches[0];
    var dx = touch.clientX - sx, dy = touch.clientY - sy, dt = Date.now() - st;
    st = 0;
    if (dt > 700 || Math.abs(dx) < 40 || Math.abs(dx) < Math.abs(dy) * 1.4) return;
    if (!shown(byId('modal-photo-nav'))) return;
    var b = byId(dx < 0 ? 'mnext' : 'mprev');
    if (b && !b.disabled) b.click();
  }, { passive: true });

  // ---- diagnose: the page's own account of itself, for failure reports ------------
  function diagnose() {
    var status = byId('search-status');
    var input = byId('search-input'), button = byId('search-btn');
    var nav = null;
    try { nav = performance.getEntriesByType('navigation')[0] || null; } catch (e) { nav = null; }
    var cookies = String(document.cookie || '').split(';').map(function (c) { return c.split('=')[0].trim(); }).filter(Boolean);
    var storage = [];
    try { for (var i = 0; i < localStorage.length && i < 40; i++) storage.push(localStorage.key(i)); } catch (e) { storage = ['(unavailable)']; }
    var challenge = $$('#challenge-form, #challenge-running, #challenge-stage, #cf-wrapper, .cf-browser-verification, .cf-error-details, ' +
      '[name="cf-turnstile-response"], iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"], iframe[src*="captcha"], .g-recaptcha, .h-captcha')
      .slice(0, 8).map(function (el) { return el.tagName.toLowerCase() + (el.id ? '#' + el.id : ''); });
    var vignette = byId('custom-vignette');
    var profile = readProfile();
    var net = (window.__nvNetLog || []).slice(-25).map(function (n) {
      return new Date(n.at).toISOString().slice(11, 23) + '  ' + n.method + ' ' + (n.status || 'failed') + ' ' + n.ms + ' ms  ' + n.url + (n.note ? '  (' + n.note + ')' : '');
    });
    var open = window.__nvNetPending || {};
    var waiting = Object.keys(open).map(function (k) { var q = open[k]; return q.method + ' ' + q.url + ', ' + (Date.now() - q.t0) + ' ms so far'; });
    var visible = '';
    try { visible = String((document.body && document.body.innerText) || '').replace(/\s+/g, ' ').trim(); } catch (e) { visible = ''; }
    return {
      engine: 3,
      url: location.href,
      title: document.title,
      readyState: document.readyState,
      visibility: document.visibilityState,
      online: navigator.onLine,
      sinceLoad: Math.round(performance.now()),
      navigation: nav ? { type: nav.type || '', status: nav.responseStatus || 0, ms: Math.round(nav.duration || 0), size: nav.transferSize || 0 } : null,
      userAgent: navigator.userAgent,
      language: navigator.language || '',
      webdriver: !!navigator.webdriver,
      viewport: window.innerWidth + 'x' + window.innerHeight + ' @' + (window.devicePixelRatio || 1) + 'x',
      searchBox: !!input,
      searchValue: input ? String(input.value || '') : '',
      searchButton: !!button,
      buttonDisabled: !!(button && button.disabled),
      buttonText: raw(button),
      status: raw(status),
      statusHTML: status ? clip(status.innerHTML, 400) : '',
      statusClass: status ? String(status.className || '') : '',
      profile: profile ? profile.handle : '',
      modal: modalOpen(),
      comments: commentsOpen(),
      vignette: !!(vignette && vignette.style.display !== 'none' && shown(vignette)),
      challenge: challenge,
      cookies: cookies,
      storage: storage,
      errors: recentErrors.slice(),
      net: net,
      waiting: waiting,
      bodyText: clip(visible, 600)
    };
  }

  // ---- readiness ---------------------------------------------------------------
  var readySent = false;
  function sendReady() {
    if (readySent) return;
    if (!byId('search-input') || !byId('search-btn')) return;
    readySent = true;
    post('ready', { url: location.href });
    scan();
  }

  window.__nv = {
    version: 3,
    search: search,
    diagnose: diagnose,
    lookup: lookup,
    profile: readProfile,
    tabState: tabState,
    openTab: openTab,
    loadMore: loadMore,
    openItem: openItem,
    currentItem: readItem,
    closeItem: closeItem,
    audio: requestAudio,
    comments: openComments,
    commentsState: function () { return commentsState(''); },
    moreComments: moreComments,
    replies: openReplies,
    moreReplies: moreReplies,
    closeComments: closeComments,
    analytics: analytics,
    closeOverlays: closeOverlays
  };

  new MutationObserver(schedule).observe(document.documentElement, {
    subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['class', 'style']
  });
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { setTimeout(sendReady, 250); });
  } else {
    setTimeout(sendReady, 250);
  }
  window.addEventListener('load', sendReady);
  // A check page or a redesign: say so instead of spinning forever.
  setTimeout(function () {
    sendReady();
    if (!readySent) post('noSearchBox', { title: document.title, url: location.href });
  }, 4000);
})();
"""#
}
