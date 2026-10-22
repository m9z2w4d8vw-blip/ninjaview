import Foundation

/// The signed-in Instagram engine, injected into instagram.com at document start so its
/// story/highlight guard is in place before the page runs. Byte-identical to the tested
/// igsession.js (see the README). It reads posts and comments only and refuses every
/// story and highlight click, request and navigation.
enum IGSessionAssets {
    static let engineJS = #"""
/* NinjaView signed-in Instagram engine: posts and comments only.
   Never opens, loads or marks seen any story or highlight: a guard installed at
   document start refuses those clicks, navigations and network requests. */
(function () {
  'use strict';
  if (window.__igl) return;

  function post(type, body) {
    try { var m = { type: type }; for (var k in (body || {})) m[k] = body[k]; window.webkit.messageHandlers.igl.postMessage(m); } catch (e) {}
  }
  var blocked = [];
  function note(what) { blocked.push(what); post('blocked', { what: what }); }

  // ---------- Guard: stories and highlights are off limits ----------
  var STORY_URL = /\/stories\/|\/highlights?\/|reels_media|reels_tray|reel\/seen|story_?viewer|highlight/i;
  // Only block operations that directly view or mark stories as seen.
  // Broad keyword matching (Highlight, ReelsMedia, Story…) was intercepting Instagram's
  // session-verification GraphQL call, causing an immediate redirect to the login page
  // every time a profile was loaded while already signed in.
  var STORY_QUERY = /\bReelsTray\b|\bSeenMutation\b/i;
  function isStoryRequest(url, body) {
    if (STORY_URL.test(String(url || ''))) return true;
    var b = typeof body === 'string' ? body : '';
    var name = (b.match(/fb_api_req_friendly_name=([^&]+)/) || [])[1] || '';
    return STORY_QUERY.test(decodeURIComponent(name));
  }
  var realFetch = window.fetch;
  if (realFetch) {
    window.fetch = function (input, init) {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (isStoryRequest(url, init && init.body)) { note('fetch ' + url.slice(0, 120)); return Promise.reject(new TypeError('blocked by NinjaView')); }
      return realFetch.apply(this, arguments).then(function (res) { capture(url, res); return res; });
    };
  }
  var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__iglUrl = u; return XO.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function (body) {
    if (isStoryRequest(this.__iglUrl, body)) { note('xhr ' + String(this.__iglUrl).slice(0, 120)); try { this.abort(); } catch (e) {} return; }
    var xhr = this;
    xhr.addEventListener('load', function () { try { if (/json|javascript/.test(xhr.getResponseHeader('content-type') || '')) walk(JSON.parse(xhr.responseText.replace(/^for \(;;\);/, ''))); } catch (e) {} });
    return XS.apply(this, arguments);
  };
  ['pushState', 'replaceState'].forEach(function (k) {
    var real = history[k];
    history[k] = function (s, t, url) {
      if (url && STORY_URL.test(String(url))) { note(k + ' ' + url); return; }
      return real.apply(this, arguments);
    };
  });
  function storyTarget(el) {
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      var label = n.getAttribute('aria-label') || '';
      if (/highlight|story/i.test(label)) return true;
      if (n.tagName === 'A' && STORY_URL.test(n.getAttribute('href') || '')) return true;
      // The profile picture in a profile header opens stories when it has a ring.
      if (n.tagName === 'HEADER' && el.closest && (el.closest('canvas') || (el.tagName === 'IMG' && /profile picture/i.test(el.alt || '')) || el.querySelector && el.querySelector('img[alt$="profile picture"]'))) return true;
    }
    return false;
  }
  ['click', 'pointerdown', 'mousedown', 'touchstart', 'keydown'].forEach(function (type) {
    document.addEventListener(type, function (e) {
      if (e.isTrusted === false && type !== 'click') return;
      if (e.target && e.target.nodeType === 1 && storyTarget(e.target)) { e.preventDefault(); e.stopImmediatePropagation(); if (type === 'click') note('click ' + (e.target.getAttribute('aria-label') || e.target.tagName)); }
    }, true);
  });

  // ---------- Media the page itself loads (real video URLs, full-size images) ----------
  var media = {};
  function best(list) {
    var top = null;
    (list || []).forEach(function (c) { if (c && c.url && (!top || (c.width || 0) * (c.height || 0) > (top.width || 0) * (top.height || 0))) top = c; });
    return top;
  }
  function mediaItem(n) {
    var img = best(n.image_versions2 && n.image_versions2.candidates), vid = best(n.video_versions);
    return { image: img ? img.url : '', video: vid ? vid.url : '' };
  }
  function walk(o, depth) {
    if (!o || typeof o !== 'object' || (depth = depth || 0) > 40) return;
    if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) walk(o[i], depth + 1); return; }
    if (typeof o.code === 'string' && (o.image_versions2 || o.carousel_media || o.video_versions)) {
      var items = o.carousel_media && o.carousel_media.length ? o.carousel_media.map(mediaItem) : [mediaItem(o)];
      media[o.code] = { taken: o.taken_at || 0, caption: (o.caption && o.caption.text) || '', likes: o.like_count || 0,
                        comments: o.comment_count || 0, items: items.filter(function (x) { return x.image || x.video; }) };
    }
    for (var k in o) if (o.hasOwnProperty(k) && o[k] && typeof o[k] === 'object') walk(o[k], depth + 1);
  }
  function capture(url, res) {
    try {
      if (!/graphql|\/api\/v1\//.test(url)) return;
      res.clone().text().then(function (t) { try { walk(JSON.parse(t.replace(/^for \(;;\);/, ''))); } catch (e) {} });
    } catch (e) {}
  }

  // ---------- Helpers ----------
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function q(s, r) { return (r || document).querySelector(s); }
  function qa(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
  function squash(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
  function text(el) { return el ? squash(el.textContent) : ''; }
  function longText(el) { return el ? String(el.innerText || el.textContent || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim() : ''; }
  function visible(el) {
    if (!el || !el.isConnected) return false;
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) { var cs = getComputedStyle(n); if (cs.display === 'none' || cs.visibility === 'hidden') return false; }
    return true;
  }
  function count(s) {
    var m = String(s || '').replace(/,/g, '').match(/([\d.]+)\s*([KM]?)/i);
    return m ? Math.round(parseFloat(m[1]) * ({ K: 1e3, M: 1e6 }[m[2].toUpperCase()] || 1)) : 0;
  }
  function imgURL(img) {
    if (!img) return '';
    var set = img.getAttribute('srcset') || '', top = '', w = 0;
    set.split(',').forEach(function (part) { var p = part.trim().split(/\s+/); var pw = parseInt(p[1], 10) || 0; if (p[0] && pw >= w) { w = pw; top = p[0]; } });
    var src = top || img.currentSrc || img.getAttribute('src') || '';
    return /^https?:/i.test(src) ? src : '';
  }
  function button(re, root) {
    return qa('button, [role="button"]', root || document).filter(function (b) {
      return visible(b) && (re.test(b.getAttribute('aria-label') || '') || re.test(text(b))) && !storyTarget(b);
    });
  }
  function codeFrom(href) { var m = String(href || '').match(/\/(p|reel|tv)\/([\w-]+)/); return m ? { kind: m[1], code: m[2] } : null; }

  // ---------- Session state and sign-in ----------
  function state() {
    var form = !!q('input[name="username"]') && !!q('input[name="password"]');
    var onLoginPath = /\/accounts\/login|\/accounts\/emailsignup/.test(location.pathname);
    var challenge = /\/challenge|\/two_factor|\/checkpoint|\/auth_platform/.test(location.pathname) ||
                    !!q('input[name="verificationCode"], input[name="security_code"], input[autocomplete="one-time-code"]');
    // Signs of being signed in, any one of which is enough: the nav icons, a link to the inbox,
    // the new-post control, a link to your own profile, or a feed with no login/sign-up links.
    var navHit = !!q('svg[aria-label="Home"], [aria-label="Home"], svg[aria-label="New post"], [aria-label="New post"], a[href*="/direct/"], a[href="/explore/"]');
    var loginLinks = !!q('a[href*="/accounts/login"], a[href*="/accounts/emailsignup"]');
    var feed = !!q('main article') || !!q('[role="feed"]');
    var loggedIn = !challenge && (navHit || (feed && !loginLinks && !form)) && !onLoginPath;
    var alert = q('#slfErrorAlert, [role="alert"]');
    return { url: location.href, loggedIn: loggedIn, loginForm: form && !loggedIn, challenge: challenge,
             error: alert && visible(alert) ? text(alert) : '' };
  }
  function typeInto(input, value) {
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    input.focus();
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function dismissPrompts() {
    // Cookie banners and "Save your login info?" / "Turn on notifications?" prompts.
    var hits = button(/^(Not now|Allow all cookies|Only allow essential cookies|Decline optional cookies)$/i);
    hits.forEach(function (b) { b.click(); });
    return hits.length;
  }
  async function login(username, password, timeoutMs) {
    dismissPrompts();
    var user = q('input[name="username"]'), pass = q('input[name="password"]');
    if (!user || !pass) return state();
    typeInto(user, username);
    typeInto(pass, password);
    await sleep(300);
    var submit = q('button[type="submit"]') || button(/^Log in$/i)[0];
    if (submit) submit.click();
    var deadline = Date.now() + (timeoutMs || 25000);
    while (Date.now() < deadline) {
      await sleep(500);
      dismissPrompts();
      var s = state();
      if (s.loggedIn || s.challenge || s.error) return s;
    }
    return state();
  }

  // ---------- Profile grid: scroll to the very end ----------

  // NOTE: CDN URL → shortcode decoding was removed.
  // The numeric ID in a CDN URL is the PHOTO/VIDEO FILE ID, not the POST shortcode.
  // Decoding it produced wrong codes that showed carousel photos as fake duplicate posts
  // and caused "not found" errors when opening them.

  function gridCodes(found) {
    // Primary source: walk()-intercepted GraphQL API responses.
    // These carry the real post shortcode (o.code) and full media URLs.
    for (var code in media) {
      if (!found.has(code)) {
        var m = media[code];
        var items = m.items || [];
        found.set(code, { code: code,
          kind: items.some(function (i) { return !!i.video; }) ? 'reel' : 'p',
          thumb: items[0] ? (items[0].image || '') : '',
          pinned: false, multi: items.length > 1,
          video: items.some(function (i) { return !!i.video; }) });
      }
    }
    // Legacy fallback: old Instagram used href="/p/CODE/" on grid anchors.
    qa('main a[href]').forEach(function (a) {
      if (a.closest('[role="dialog"]')) return;
      var c = codeFrom(a.getAttribute('href'));
      if (!c || found.has(c.code)) return;
      found.set(c.code, { code: c.code, kind: c.kind, thumb: imgURL(q('img', a)),
        pinned: !!q('svg[aria-label*="Pinned"]', a), multi: !!q('svg[aria-label="Carousel"]', a),
        video: !!q('svg[aria-label="Clip"], svg[aria-label="Reel"], svg[aria-label="Video"]', a) });
    });
    return found;
  }
  function postsTotal() {
    var hit = qa('header li, header span, header a').map(text).filter(function (t) { return /^[\d.,KM]+\s+posts?$/i.test(t); })[0];
    return hit ? count(hit) : 0;
  }
  async function grid(opts) {
    opts = opts || {};
    var budget = Date.now() + (opts.maxMs || 15 * 60 * 1000), idleWanted = opts.idleRounds || 6, wait = opts.waitMs || 2500;
    var found = gridCodes(new Map()), total = postsTotal(), idle = 0, rounds = 0;
    while (Date.now() < budget && idle < idleWanted && (!total || found.size < total)) {
      dismissPrompts();
      var before = found.size;
      // Scroll to the bottom to trigger Instagram's infinite-scroll API calls.
      // In current Instagram there are no href links on grid items; fall back to
      // scrolling the last <a> in main (still a grid cell, just without href).
      var links = qa('main a[href*="/p/"], main a[href*="/reel/"]');
      var scrollTarget = links.length ? links : qa('main a');
      if (scrollTarget.length) scrollTarget[scrollTarget.length - 1].scrollIntoView({ block: 'end' });
      window.scrollTo(0, document.documentElement.scrollHeight);
      var until = Date.now() + wait;
      while (Date.now() < until) { await sleep(250); gridCodes(found); if (found.size > before) break; }
      idle = found.size > before ? 0 : idle + 1;
      rounds++;
      if (rounds % 5 === 0) post('progress', { stage: 'grid', found: found.size, total: total });
    }
    // Sort newest-first to match Instagram's grid order.
    var sorted = Array.from(found.values()).sort(function (a, b) {
      return (media[b.code] ? media[b.code].taken : 0) - (media[a.code] ? media[a.code].taken : 0);
    });
    return { total: total, items: sorted, ended: !!total && found.size >= total, rounds: rounds,
             reason: total && found.size >= total ? 'all' : (idle >= idleWanted ? 'nothing more loaded' : 'time limit') };
  }

  // ---------- A post: expand everything, then read it ----------
  function postRoot() {
    var d = q('[role="dialog"] article') || q('[role="dialog"]');
    return d || q('main article') || q('main') || document.body;
  }
  function commentTimes(root) { return qa('a[href*="/c/"] time', root); }
  function readComments(root) {
    var out = [], seen = {};
    commentTimes(root).forEach(function (t) {
      var a = t.closest('a'), m = (a.getAttribute('href') || '').match(/\/c\/(\d+)(?:\/r\/(\d+))?/);
      if (!m) return;
      var id = m[2] || m[1], parent = m[2] ? m[1] : '';
      if (seen[id]) return;
      seen[id] = true;
      var box = a;
      while (box.parentElement && box.parentElement !== root && commentTimes(box.parentElement).length === 1) box = box.parentElement;
      var h3 = q('h3', box);
      var author = h3 ? text(q('a', h3)) || text(h3) : '';
      var body = qa('span[dir="auto"]', box).filter(function (s) { return !(h3 && h3.contains(s)) && !s.closest('span[dir="ltr"]'); })[0];
      var likeBtn = qa('button, [role="button"]', box).map(text).filter(function (s) { return /^[\d.,KM]+\s+likes?$/i.test(s); })[0];
      var avatar = q('img[alt$="profile picture"]', box);
      out.push({ id: id, parent: parent, author: author, verified: !!(h3 && q('svg[aria-label="Verified"]', h3)),
                 text: longText(body), time: t.getAttribute('datetime') || '', likes: likeBtn ? count(likeBtn) : 0,
                 avatar: imgURL(avatar) });
    });
    return out;
  }
  function inComments(el) {
    var li = el.closest('li');
    return !!(li && (q('time', li) || q('h3', li) || q('h1', li)));
  }
  function visibleMedia(root, into) {
    qa('img', root).forEach(function (img) {
      if (/profile picture|highlight/i.test(img.alt || '') || inComments(img)) return;
      var r = img.getBoundingClientRect();
      if (Math.max(r.width, img.naturalWidth || 0) < 150) return;
      var url = imgURL(img);
      var key = url || ('alt:' + (img.alt || '') + ':' + into.length);
      if (!into.some(function (x) { return x.key === key; })) into.push({ key: key, image: url, video: '', alt: img.alt || '' });
    });
    qa('video', root).forEach(function (v) {
      var src = v.currentSrc || v.getAttribute('src') || '';
      var key = 'video:' + (src || v.getAttribute('poster') || into.length);
      if (!into.some(function (x) { return x.key === key; }))
        into.push({ key: key, image: v.getAttribute('poster') || '', video: /^https?:/.test(src) ? src : '', alt: '' });
    });
  }
  function carouselNext(root) {
    var art = root.closest ? (root.tagName === 'ARTICLE' ? root : q('article', root) || root) : root;
    return qa('button[aria-label="Next"], [role="button"][aria-label="Next"]', art).filter(function (b) { return visible(b) && b.closest('article'); })[0];
  }
  async function expand(root, opts) {
    var limit = opts.maxComments || 3000, deadline = Date.now() + (opts.maxMs || 5 * 60 * 1000), wait = opts.waitMs || 2000;
    var rounds = 0, tries = new WeakMap();
    function fresh(b) { return (tries.get(b) || 0) < 2; }   // a control that did nothing twice is skipped
    while (Date.now() < deadline && rounds < (opts.maxRounds || 400)) {
      dismissPrompts();
      var more = button(/^Load more comments$|^View more comments$|^View all \d+ comments$/i, root).filter(fresh)[0];
      var threads = button(/^View (all )?(\d+ )?(more )?repl(y|ies)( \(\d+\))?$/i, root).filter(fresh);
      var target = threads[0] || more;
      if (!target || commentTimes(root).length >= limit) break;
      var before = commentTimes(root).length;
      target.click();
      var until = Date.now() + wait;
      while (Date.now() < until && commentTimes(root).length === before && target.isConnected && visible(target)) await sleep(200);
      if (commentTimes(root).length === before) tries.set(target, (tries.get(target) || 0) + 1);
      rounds++;
      if (rounds % 10 === 0) post('progress', { stage: 'comments', found: commentTimes(root).length });
    }
    return rounds;
  }
  async function readPost(opts) {
    opts = opts || {};
    var root = postRoot();
    var here = codeFrom(location.pathname) || codeFrom((q('a[href*="/p/"] time', root) || {}).parentElement && q('a[href*="/p/"] time', root).parentElement.getAttribute('href'));
    var code = here ? here.code : '';
    var rounds = opts.comments === false ? 0 : await expand(root, opts);
    var found = [];
    visibleMedia(root, found);
    for (var i = 0; i < 25; i++) {
      var next = carouselNext(root);
      if (!next) break;
      next.click();
      await sleep(opts.slideMs || 600);
      visibleMedia(root, found);
    }
    var captionRow = q('h1', root);
    var dated = qa('time', root).filter(function (t) { return !t.closest('a[href*="/c/"]'); })[0];
    var likesText = qa('a, span', root).filter(function (el) { return !el.closest('button') && !el.closest('li') && /^[\d.,KM]+\s+likes?$/i.test(text(el)); }).map(text)[0] || '';
    var authorLink = qa('header a[href]', root).filter(function (a) { return /^\/?[\w.]+\/?$/.test((a.getAttribute('href') || '').replace(/^https:\/\/www\.instagram\.com/, '')) && text(a); })[0];
    var net = media[code];
    return {
      code: code, author: authorLink ? text(authorLink) : '', caption: longText(captionRow) || (net ? net.caption : ''),
      date: dated ? dated.getAttribute('datetime') || '' : (net && net.taken ? new Date(net.taken * 1000).toISOString() : ''),
      likes: likesText ? count(likesText) : (net ? net.likes : 0),
      media: net && net.items.length ? net.items.map(function (x) { return { image: x.image, video: x.video, alt: '' }; })
                                     : found.map(function (x) { return { image: x.image, video: x.video, alt: x.alt }; }),
      mediaFrom: net && net.items.length ? 'network' : 'page',
      comments: readComments(root), expandRounds: rounds
    };
  }

  window.__igl = { state: state, login: login, dismissPrompts: dismissPrompts, grid: grid, post: readPost,
                   blocked: function () { return blocked.slice(); }, media: function () { return media; } };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { post('ready', { url: location.href }); });
  else post('ready', { url: location.href });
})();
"""#
}
